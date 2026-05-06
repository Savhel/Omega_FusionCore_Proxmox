//! Gestionnaire de balloon RAM — thin-provisioning côté guest.
//!
//! ## Principe
//!
//! La VM est créée avec `memory=<max_mib>` dans Proxmox mais le balloon QEMU
//! lui masque une partie de cette RAM au démarrage (`min_mib`).
//! Ce module surveille le taux de page-faults (proxy de la pression mémoire
//! dans le guest) et ajuste le balloon progressivement :
//!
//! - `fault_rate > grow_faults_per_sec` → dégonfler le balloon (guest voit plus de RAM)
//! - `fault_rate < shrink_faults_per_sec` → gonfler le balloon (récupérer de la RAM)
//!
//! Les bornes dures sont [`min_mib`, `max_mib`] ; on ne sort jamais de cette plage.
//!
//! ## Commande Proxmox
//!
//! `qm balloon <vmid> <mib>` — la valeur est en Mio.
//! Correspond à `PUT /nodes/{node}/qemu/{vmid}/resize` en interne mais qm
//! ballot est plus direct et ne nécessite pas de redémarrage.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use tokio::process::Command;
use tokio::time::sleep;
use tracing::{info, warn};

use crate::metrics::AgentMetrics;

pub struct BalloonManager {
    vm_id:                 u32,
    min_mib:               u64,
    max_mib:               u64,
    step_mib:              u64,
    interval:              Duration,
    grow_faults_per_sec:   u64,
    shrink_faults_per_sec: u64,
    current_mib:           Arc<AtomicU64>,
    metrics:               Arc<AgentMetrics>,
}

impl BalloonManager {
    pub fn new(
        vm_id:                 u32,
        min_mib:               u64,
        max_mib:               u64,
        step_mib:              u64,
        interval_secs:         u64,
        grow_faults_per_sec:   u64,
        shrink_faults_per_sec: u64,
        metrics:               Arc<AgentMetrics>,
    ) -> Self {
        let min_mib  = min_mib.max(64);          // plancher absolu de sécurité
        let max_mib  = max_mib.max(min_mib);
        let step_mib = step_mib.max(64);

        Self {
            vm_id,
            min_mib,
            max_mib,
            step_mib,
            interval: Duration::from_secs(interval_secs.max(5)),
            grow_faults_per_sec,
            shrink_faults_per_sec,
            current_mib: Arc::new(AtomicU64::new(min_mib)),
            metrics,
        }
    }

    pub async fn run(self: Arc<Self>, shutdown: Arc<AtomicBool>) {
        // Au démarrage : positionner le balloon à min_mib
        if let Err(e) = set_balloon(self.vm_id, self.min_mib).await {
            warn!(vm_id = self.vm_id, error = %e, "balloon init échoué — guest voit la RAM complète");
        } else {
            info!(
                vm_id   = self.vm_id,
                mib     = self.min_mib,
                max_mib = self.max_mib,
                "balloon initialisé — guest démarre avec RAM réduite"
            );
        }

        let mut prev_faults = self.metrics.fault_count.load(Ordering::Relaxed);
        let interval_secs   = self.interval.as_secs().max(1);

        loop {
            sleep(self.interval).await;

            if shutdown.load(Ordering::Relaxed) {
                // Libérer toute la RAM au guest avant l'arrêt propre
                let _ = set_balloon(self.vm_id, self.max_mib).await;
                break;
            }

            let cur_faults  = self.metrics.fault_count.load(Ordering::Relaxed);
            let delta       = cur_faults.saturating_sub(prev_faults);
            let fault_rate  = delta / interval_secs;
            prev_faults     = cur_faults;

            let current = self.current_mib.load(Ordering::Relaxed);

            let target = if fault_rate >= self.grow_faults_per_sec {
                // Pression mémoire : donner plus de RAM au guest
                (current + self.step_mib).min(self.max_mib)
            } else if fault_rate <= self.shrink_faults_per_sec && current > self.min_mib {
                // Inactivité : récupérer de la RAM
                current.saturating_sub(self.step_mib).max(self.min_mib)
            } else {
                current
            };

            if target != current {
                match set_balloon(self.vm_id, target).await {
                    Ok(_) => {
                        self.current_mib.store(target, Ordering::Relaxed);
                        info!(
                            vm_id      = self.vm_id,
                            prev_mib   = current,
                            new_mib    = target,
                            fault_rate,
                            "balloon ajusté"
                        );
                    }
                    Err(e) => warn!(vm_id = self.vm_id, error = %e, "qm balloon échoué"),
                }
            }
        }
    }
}

async fn set_balloon(vm_id: u32, mib: u64) -> anyhow::Result<()> {
    let out = Command::new("qm")
        .args(["balloon", &vm_id.to_string(), &mib.to_string()])
        .output()
        .await?;

    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        anyhow::bail!("qm balloon {vm_id} {mib}: {stderr}");
    }
    Ok(())
}
