//! Intégration virtio-balloon via QEMU Monitor Protocol (QMP) — feature V4.
//!
//! # Principe
//!
//! QEMU expose une socket de contrôle QMP pour chaque VM Proxmox :
//! `/var/run/qemu-server/{vmid}.qmp`
//!
//! On interroge périodiquement cette socket pour lire les statistiques
//! mémoire remontées par le driver virtio-balloon dans le guest.
//!
//! # Statistiques balloon disponibles
//!
//! | Champ                  | Description                               |
//! |------------------------|-------------------------------------------|
//! | stat-free-memory       | RAM libre dans le guest (octets)          |
//! | stat-available-memory  | RAM disponible (avec cache) dans le guest |
//! | stat-total-memory      | RAM totale visible par le guest           |
//! | stat-minor-faults      | Page faults mineurs (depuis démarrage)    |
//! | stat-major-faults      | Page faults majeurs = accès disque/swap   |
//!
//! # Protocole QMP
//!
//! 1. Connexion sur la socket Unix → le serveur envoie le greeting JSON
//! 2. `{"execute": "qmp_capabilities"}` → active les commandes
//! 3. `{"execute": "query-balloon"}` → retourne l'état du balloon
//! 4. Pour les stats : il faut d'abord configurer la fréquence de rapport :
//!    `{"execute": "balloon", "arguments": {"value": <target_bytes>}}`
//! 5. Puis `{"execute": "qom-get", "arguments": {"path": "/machine/peripheral/balloon0", "property": "guest-stats"}}`
//!
//! # Décision d'éviction basée sur balloon
//!
//! Si `stat-free-memory < free_threshold_pct × stat-total-memory` :
//! → augmenter le taux d'éviction de l'agent sur ce nœud
//! → signaler l'urgence au controller pour accélérer la décision de migration

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use tracing::{debug, info, trace, warn};

/// Statistiques mémoire rapportées par le balloon driver du guest.
#[derive(Debug, Clone, Default)]
pub struct BalloonStats {
    /// RAM libre dans le guest (octets)
    pub free_bytes: u64,
    /// RAM disponible dans le guest (octets, avec reclaimable)
    pub available_bytes: u64,
    /// RAM totale visible par le guest (octets)
    pub total_bytes: u64,
    /// Page faults majeurs depuis démarrage (indicateur de swap)
    pub major_faults: u64,
    /// Taille actuelle du balloon (octets retirés au guest)
    pub actual_bytes: u64,
}

impl BalloonStats {
    /// Pourcentage de RAM libre dans le guest.
    pub fn free_pct(&self) -> f64 {
        if self.total_bytes == 0 {
            return 100.0;
        }
        (self.free_bytes as f64 / self.total_bytes as f64) * 100.0
    }

    /// Pourcentage de RAM disponible dans le guest.
    pub fn available_pct(&self) -> f64 {
        if self.total_bytes == 0 {
            return 100.0;
        }
        (self.available_bytes as f64 / self.total_bytes as f64) * 100.0
    }

    /// Le guest est-il sous pression mémoire ?
    pub fn is_under_pressure(&self, free_threshold_pct: f64) -> bool {
        self.free_pct() < free_threshold_pct
    }
}

/// Client QMP pour un VMID Proxmox donné.
pub struct QmpClient {
    vmid: u32,
    sock_path: PathBuf,
}

impl QmpClient {
    /// Construit un client QMP pour la socket Proxmox standard.
    pub fn for_vm(vmid: u32, qmp_dir: &str) -> Self {
        Self {
            vmid,
            sock_path: PathBuf::from(format!("{}/{}.qmp", qmp_dir, vmid)),
        }
    }

    /// Interroge les statistiques balloon du guest.
    ///
    /// Retourne `None` si la socket n'existe pas ou si le balloon driver
    /// n'est pas actif dans le guest.
    pub fn query_stats(&self) -> Result<Option<BalloonStats>> {
        if !self.sock_path.exists() {
            trace!(
                vmid = self.vmid,
                "socket QMP absente — balloon non disponible"
            );
            return Ok(None);
        }

        let mut stream = UnixStream::connect(&self.sock_path)
            .with_context(|| format!("connexion QMP vmid={}", self.vmid))?;

        stream.set_read_timeout(Some(Duration::from_secs(3)))?;
        stream.set_write_timeout(Some(Duration::from_secs(3)))?;

        let mut reader = BufReader::new(stream.try_clone()?);

        // ── 1. Lire le greeting QMP ────────────────────────────────────────
        let mut greeting = String::new();
        reader.read_line(&mut greeting)?;
        trace!(vmid = self.vmid, greeting = %greeting.trim(), "QMP greeting");

        // ── 2. Activer les capacités QMP ──────────────────────────────────
        self.send_json(&mut stream, &json!({"execute": "qmp_capabilities"}))?;
        let caps_resp = self.read_response(&mut reader)?;
        if caps_resp.get("error").is_some() {
            bail!("qmp_capabilities échoué : {:?}", caps_resp);
        }

        // ── 3. Interroger l'état du balloon ───────────────────────────────
        self.send_json(&mut stream, &json!({"execute": "query-balloon"}))?;
        let balloon_resp = self.read_response(&mut reader)?;

        // Si error → balloon non disponible (driver non chargé dans le guest)
        if balloon_resp.get("error").is_some() {
            debug!(vmid = self.vmid, "balloon driver absent dans ce guest");
            return Ok(None);
        }

        let actual_bytes = balloon_resp["return"]["actual"].as_u64().unwrap_or(0);

        // ── 4. Interroger les stats guest via QOM ─────────────────────────
        self.send_json(
            &mut stream,
            &json!({
                "execute": "qom-get",
                "arguments": {
                    "path": "/machine/peripheral/balloon0",
                    "property": "guest-stats"
                }
            }),
        )?;
        let stats_resp = self.read_response(&mut reader)?;

        if stats_resp.get("error").is_some() {
            // Stats non disponibles (poll interval pas encore configuré)
            // On retourne ce qu'on a
            return Ok(Some(BalloonStats {
                actual_bytes,
                ..Default::default()
            }));
        }

        let gs = &stats_resp["return"]["stats"];

        let stats = BalloonStats {
            free_bytes: self.parse_stat(gs, "stat-free-memory"),
            available_bytes: self.parse_stat(gs, "stat-available-memory"),
            total_bytes: self.parse_stat(gs, "stat-total-memory"),
            major_faults: self.parse_stat(gs, "stat-major-faults"),
            actual_bytes,
        };

        debug!(
            vmid = self.vmid,
            free_pct = format!("{:.1}%", stats.free_pct()),
            total_mib = stats.total_bytes / 1024 / 1024,
            actual_mib = stats.actual_bytes / 1024 / 1024,
            major_faults = stats.major_faults,
            "balloon stats lues"
        );

        Ok(Some(stats))
    }

    /// Configure la fréquence de rapport des stats balloon.
    ///
    /// Doit être appelé au moins une fois avant de lire les stats.
    /// `poll_interval_secs` = 0 désactive le polling.
    pub fn set_stats_polling(&self, poll_interval_secs: u32) -> Result<()> {
        if !self.sock_path.exists() {
            return Ok(());
        }

        let mut stream = UnixStream::connect(&self.sock_path)?;
        stream.set_read_timeout(Some(Duration::from_secs(3)))?;
        let mut reader = BufReader::new(stream.try_clone()?);

        // Greeting
        let mut line = String::new();
        reader.read_line(&mut line)?;

        // Capabilities
        self.send_json(&mut stream, &json!({"execute": "qmp_capabilities"}))?;
        let _ = self.read_response(&mut reader)?;

        // Configurer l'intervalle de polling
        self.send_json(
            &mut stream,
            &json!({
                "execute": "qom-set",
                "arguments": {
                    "path": "/machine/peripheral/balloon0",
                    "property": "guest-stats-polling-interval",
                    "value": poll_interval_secs
                }
            }),
        )?;
        let resp = self.read_response(&mut reader)?;

        if resp.get("error").is_some() {
            warn!(
                vmid = self.vmid,
                "impossible de configurer le polling balloon : {:?}", resp
            );
        } else {
            info!(
                vmid = self.vmid,
                poll_interval_secs, "polling balloon configuré"
            );
        }

        Ok(())
    }

    // ─── Helpers ──────────────────────────────────────────────────────────

    fn send_json(&self, stream: &mut UnixStream, cmd: &Value) -> Result<()> {
        let mut payload = cmd.to_string();
        payload.push('\n');
        stream.write_all(payload.as_bytes())?;
        Ok(())
    }

    fn read_response(&self, reader: &mut BufReader<UnixStream>) -> Result<Value> {
        let mut line = String::new();
        reader.read_line(&mut line)?;
        // Ignorer les événements async (lignes commençant par {"event":...})
        let parsed: Value = serde_json::from_str(line.trim())?;
        if parsed.get("event").is_some() {
            // Relire la prochaine ligne
            line.clear();
            reader.read_line(&mut line)?;
            return Ok(serde_json::from_str(line.trim())?);
        }
        Ok(parsed)
    }

    fn parse_stat(&self, gs: &Value, key: &str) -> u64 {
        gs[key].as_u64().unwrap_or(0)
    }
}

// ─── Monitor balloon (tâche de fond) ─────────────────────────────────────────

/// Moniteur balloon — tourne en tâche Tokio, interroge les stats périodiquement.
pub struct BalloonMonitor {
    qmp_dir: String,
    poll_interval: Duration,
    /// Seuil de RAM libre en-dessous duquel on considère le guest sous pression (%)
    free_threshold_pct: f64,
    /// Callback déclenché quand un guest est sous pression
    /// Arguments : vmid, BalloonStats
    on_pressure: Arc<dyn Fn(u32, BalloonStats) + Send + Sync>,
}

use std::sync::Arc;

impl BalloonMonitor {
    pub fn new(
        qmp_dir: String,
        poll_interval_secs: u64,
        free_threshold_pct: f64,
        on_pressure: impl Fn(u32, BalloonStats) + Send + Sync + 'static,
    ) -> Self {
        Self {
            qmp_dir,
            poll_interval: Duration::from_secs(poll_interval_secs),
            free_threshold_pct,
            on_pressure: Arc::new(on_pressure),
        }
    }

    /// Boucle de surveillance — à lancer dans une tâche Tokio via `tokio::task::spawn_blocking`.
    pub fn run_blocking(self, vmids: Vec<u32>) {
        info!(
            vms = vmids.len(),
            threshold_pct = self.free_threshold_pct,
            interval_secs = self.poll_interval.as_secs(),
            "BalloonMonitor démarré"
        );

        // Configuration initiale du polling QMP sur chaque VM
        for &vmid in &vmids {
            let client = QmpClient::for_vm(vmid, &self.qmp_dir);
            if let Err(e) = client.set_stats_polling(self.poll_interval.as_secs() as u32) {
                debug!(vmid, error = %e, "configuration polling balloon ignorée");
            }
        }

        loop {
            std::thread::sleep(self.poll_interval);

            for &vmid in &vmids {
                let client = QmpClient::for_vm(vmid, &self.qmp_dir);
                match client.query_stats() {
                    Ok(Some(stats)) => {
                        if stats.is_under_pressure(self.free_threshold_pct) {
                            info!(
                                vmid,
                                free_pct = format!("{:.1}%", stats.free_pct()),
                                threshold = format!("{:.1}%", self.free_threshold_pct),
                                "pression balloon détectée → augmentation taux d'éviction"
                            );
                            (self.on_pressure)(vmid, stats);
                        } else {
                            trace!(
                                vmid,
                                free_pct = format!("{:.1}%", stats.free_pct()),
                                "balloon ok"
                            );
                        }
                    }
                    Ok(None) => trace!(vmid, "balloon non disponible"),
                    Err(e) => debug!(vmid, error = %e, "erreur lecture balloon"),
                }
            }
        }
    }
}
