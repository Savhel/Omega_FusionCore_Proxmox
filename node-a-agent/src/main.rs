//! Point d'entrée de l'agent nœud A.
//!
//! # Mode "demo"
//!
//! Scénario de validation complet exécuté automatiquement :
//!
//! 1. Connexion aux stores B et C (ping de sanité).
//! 2. Allocation d'une région mémoire + enregistrement userfaultfd.
//! 3. Écriture de valeurs connues dans N pages.
//! 4. Éviction des pages paires vers les stores.
//! 5. Lecture de toutes les pages → les pages paires déclenchent des page faults.
//! 6. Vérification de l'intégrité des données.
//! 7. Affichage des métriques finales.
//!
//! # Mode "daemon"
//!
//! L'agent reste actif et attend SIGTERM/SIGINT pour s'arrêter.
//! (Prévu pour l'intégration future avec le controller.)

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Instant;

use anyhow::{bail, Context, Result};
use clap::Parser;
use tracing::{error, info, warn};
use tracing_subscriber::{fmt, EnvFilter};

use node_a_agent::config::Config;
use node_a_agent::memory::{MemoryRegion, PAGE_SIZE};
use node_a_agent::metrics::AgentMetrics;
use node_a_agent::remote::RemoteStorePool;
use node_a_agent::uffd::{spawn_fault_handler_thread, UffdHandle};

#[tokio::main]
async fn main() -> Result<()> {
    let cfg = Config::parse();

    // ------------------------------------------------------------------ logging
    let filter =
        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(&cfg.log_level));

    match cfg.log_format.as_str() {
        "json" => fmt()
            .json()
            .with_env_filter(filter)
            .with_current_span(false)
            .init(),
        _ => fmt().with_env_filter(filter).with_target(false).init(),
    }

    info!(
        vm_id      = cfg.vm_id,
        stores     = ?cfg.stores,
        region_mib = cfg.region_mib,
        mode       = %cfg.mode,
        "agent démarré"
    );

    // ------------------------------------------------------------------ pool de stores
    let store = Arc::new(RemoteStorePool::new(
        cfg.stores.clone(),
        cfg.store_timeout_ms,
    ));

    // Vérification de la connectivité
    info!("vérification de la connectivité aux stores...");
    let ping_results = store.ping_all().await;
    let mut stores_ok = 0;
    for (idx, ok) in &ping_results {
        if *ok {
            info!(store_idx = idx, addr = %cfg.stores[*idx], "store: PONG ok");
            stores_ok += 1;
        } else {
            warn!(store_idx = idx, addr = %cfg.stores[*idx], "store: pas de réponse (store démarré ?)");
        }
    }
    if stores_ok == 0 {
        bail!("aucun store disponible — vérifiez que node-bc-store tourne sur B et C");
    }
    info!(
        stores_ok = stores_ok,
        total = cfg.stores.len(),
        "stores disponibles"
    );

    // ------------------------------------------------------------------ runtime Tokio (handle pour block_on depuis threads)
    let tokio_handle = tokio::runtime::Handle::current();

    // ------------------------------------------------------------------ métriques
    let metrics = Arc::new(AgentMetrics::default());

    // ------------------------------------------------------------------ région mémoire
    let region_size = cfg.region_mib * 1024 * 1024;
    let region = Arc::new(
        MemoryRegion::allocate(
            region_size,
            cfg.vm_id,
            store.clone(),
            metrics.clone(),
            tokio_handle.clone(),
        )
        .context("allocation de la région mémoire échouée")?,
    );

    // ------------------------------------------------------------------ userfaultfd
    let uffd = UffdHandle::open()
        .context("ouverture userfaultfd échouée — kernel ≥ 4.11 requis, ou activer /proc/sys/vm/unprivileged_userfaultfd")?;

    uffd.register_region(region.base_ptr(), region_size)
        .context("enregistrement région uffd échoué")?;

    // ------------------------------------------------------------------ thread handler uffd
    let shutdown_flag = Arc::new(AtomicBool::new(false));
    let region_start = region.base_ptr() as u64;

    // Le handler est un closure qui appelle region.fetch_page()
    let region_for_handler = region.clone();
    let fault_handler = Box::new(move |_vm_id: u32, page_id: u64, _addr: u64, _write: bool| {
        region_for_handler.fetch_page(page_id)
    });

    let handler_thread = spawn_fault_handler_thread(
        uffd,
        region_start,
        PAGE_SIZE as u64,
        cfg.vm_id,
        fault_handler,
        shutdown_flag.clone(),
        metrics.clone(),
    );

    // ------------------------------------------------------------------ exécution selon le mode
    match cfg.mode.as_str() {
        "demo" => run_demo(&region, &cfg, &metrics, &store).await?,
        "daemon" => run_daemon(&shutdown_flag).await,
        m => bail!("mode inconnu : {m} (valides : demo, daemon)"),
    }

    // ------------------------------------------------------------------ arrêt propre
    info!("signal d'arrêt envoyé au thread uffd-handler");
    shutdown_flag.store(true, Ordering::Relaxed);

    // On ne joint pas le thread handler ici car il est bloqué sur read(uffd_fd).
    // Fermer le fd suffirait mais le fd est dropped avec UffdHandle.
    // En production : utiliser un eventfd ou un pipe pour débloquer proprement.
    // En demo : le process se termine et tout est nettoyé par l'OS.
    let _ = handler_thread; // thread détaché, terminé avec le process

    let snap = metrics.snapshot();
    info!(
        faults = snap.fault_count,
        served = snap.fault_served,
        errors = snap.fault_errors,
        evicted = snap.pages_evicted,
        fetched = snap.pages_fetched,
        zeros = snap.fetch_zeros,
        "métriques finales"
    );

    Ok(())
}

/// Scénario de démonstration et validation.
async fn run_demo(
    region: &Arc<MemoryRegion>,
    _cfg: &Config,
    metrics: &Arc<AgentMetrics>,
    _store: &Arc<RemoteStorePool>,
) -> Result<()> {
    let num_pages = region.num_pages;
    let demo_pages = num_pages.min(64); // on travaille sur 64 pages max pour le demo

    info!(demo_pages, "=== début du scénario de démonstration ===");

    // ------------------------------------------------------------------ 1. Écriture de valeurs connues
    info!(
        "étape 1/4 : écriture des valeurs initiales dans {} pages",
        demo_pages
    );
    for page_id in 0..demo_pages as u64 {
        let mut data = [0u8; PAGE_SIZE];
        // Signature reconnaissable : les 8 premiers octets encodent page_id
        data[..8].copy_from_slice(&page_id.to_be_bytes());
        // Remplissage avec un motif dérivé du page_id
        for i in 8..PAGE_SIZE {
            data[i] = ((page_id as u8).wrapping_add(i as u8)) & 0xFF;
        }
        region
            .write_page_local(page_id, &data)
            .with_context(|| format!("écriture page {page_id}"))?;
    }
    info!("étape 1/4 : ok");

    // ------------------------------------------------------------------ 2. Éviction des pages paires
    info!("étape 2/4 : éviction des pages paires vers les stores distants");
    let t0 = Instant::now();
    let mut evicted = 0u64;
    for page_id in (0..demo_pages as u64).step_by(2) {
        region
            .evict_page(page_id)
            .with_context(|| format!("éviction page {page_id}"))?;
        evicted += 1;
    }
    let evict_ms = t0.elapsed().as_millis();
    info!(
        evicted = evicted,
        elapsed_ms = evict_ms,
        throughput_kbps = evicted * 4 * 1000 / evict_ms.max(1) as u64,
        "étape 2/4 : ok"
    );

    // ------------------------------------------------------------------ 3. Lecture de toutes les pages (déclenche les page faults)
    info!("étape 3/4 : lecture de toutes les pages (page faults attendus pour les paires)");
    let t1 = Instant::now();
    let mut errors = 0u32;

    for page_id in 0..demo_pages as u64 {
        // Lecture via un pointeur direct dans la région — déclenche une page fault
        // si la page a été évinvée (MADV_DONTNEED → absent → uffd intercepte)
        let ptr = unsafe { (region.base_ptr() as *const u8).add(page_id as usize * PAGE_SIZE) };

        // Lecture des 8 premiers octets (signature page_id)
        let read_page_id = unsafe { u64::from_be_bytes(*(ptr as *const [u8; 8])) };

        // Vérification de l'intégrité
        if read_page_id != page_id {
            error!(
                page_id = page_id,
                got_page_id = read_page_id,
                was_remote = page_id % 2 == 0,
                "ERREUR INTÉGRITÉ : données corrompues !"
            );
            errors += 1;
        }

        // Vérification du motif complet pour les 16 premiers octets supplémentaires
        let ok = (8..24).all(|i| {
            let expected = ((page_id as u8).wrapping_add(i as u8)) & 0xFF;
            let got = unsafe { *ptr.add(i) };
            got == expected
        });

        if !ok {
            error!(page_id, "ERREUR INTÉGRITÉ : motif incorrect");
            errors += 1;
        }
    }

    let read_ms = t1.elapsed().as_millis();
    info!(
        pages = demo_pages,
        elapsed_ms = read_ms,
        errors = errors,
        "étape 3/4 : lecture terminée"
    );

    // ------------------------------------------------------------------ 4. Résultat
    let snap = metrics.snapshot();
    info!("étape 4/4 : résultats");
    info!(
        pages_evicted = snap.pages_evicted,
        faults_caught = snap.fault_count,
        faults_served = snap.fault_served,
        faults_errors = snap.fault_errors,
        fetch_zeros = snap.fetch_zeros,
        integrity_ok = errors == 0,
        "=== fin du scénario de démonstration ==="
    );

    if errors > 0 {
        bail!("ÉCHEC : {} erreur(s) d'intégrité détectée(s)", errors);
    }

    info!("SUCCÈS : toutes les pages lues avec intégrité correcte");
    Ok(())
}

/// Mode daemon : attend SIGINT/SIGTERM.
async fn run_daemon(shutdown_flag: &Arc<AtomicBool>) {
    info!("mode daemon — en attente (CTRL+C pour arrêter)");
    tokio::signal::ctrl_c()
        .await
        .expect("impossible d'écouter SIGINT");
    info!("SIGINT reçu — arrêt");
    shutdown_flag.store(true, Ordering::Relaxed);
}
