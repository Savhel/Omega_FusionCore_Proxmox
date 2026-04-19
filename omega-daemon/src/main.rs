//! omega-daemon V4 — daemon unifié multi-rôle pour cluster Proxmox.
//!
//! # Rôles simultanés
//!
//!   1. **Store TCP**    (port 9100) → accepte pages distantes de tout nœud
//!   2. **API HTTP**     (port 9200) → état nœud exposé au cluster
//!   3. **Control HTTP** (port 9300) → canal contrôle controller↔agent (fix L2)
//!   4. **VM Monitor**               → VMs QEMU locales via filesystem Proxmox
//!   5. **Eviction Engine**          → CLOCK + balloon trigger (fix L1, feat V4)
//!   6. **Balloon Monitor**          → stats virtio-balloon via QMP (V4)
//!
//! # Démarrage
//!
//! ```bash
//! omega-daemon \
//!     --node-id pve-node1 \
//!     --node-addr 192.168.1.1 \
//!     --peers 192.168.1.2:9200,192.168.1.3:9200
//! ```

use std::collections::{HashMap, HashSet};
use std::fs;
use std::sync::Arc;
use std::time::Duration;
use std::time::Instant;

extern crate num_cpus;

use anyhow::Result;
use clap::Parser;
use tracing::{error, info, warn};
use tracing_subscriber::{fmt, EnvFilter};

use node_bc_store::metrics::StoreMetrics;
use node_bc_store::store::PageStore;

use omega_daemon::balloon::{BalloonMonitor, BalloonStats};
use omega_daemon::cluster_api::run_api_server;
use omega_daemon::config::Config;
use omega_daemon::control_api::build_control_router;
use omega_daemon::cpu_cgroup::{CgroupCpuController, VmCpuConfig, VmCpuStat};
use omega_daemon::eviction_engine::EvictionEngine;
use omega_daemon::fault_bus::{FaultBus, FaultBusConsumer};
use omega_daemon::gpu_drm_backend::DrmGpuBackend;
use omega_daemon::gpu_multiplexer::{GpuBackend, GpuMultiplexer};
use omega_daemon::gpu_runtime::GpuRuntime;
use omega_daemon::node_state::NodeState;
use omega_daemon::qmp_vcpu::{HotplugResult, VcpuHotplugManager};
use omega_daemon::store_server::run_store_server;
use omega_daemon::tls::{TlsContext, TlsPaths};
use omega_daemon::vm_tracker::VmTracker;

#[tokio::main]
async fn main() -> Result<()> {
    let cfg = Config::parse();
    setup_logging(&cfg);

    info!(
        version      = env!("CARGO_PKG_VERSION"),
        node_id      = %cfg.node_id,
        addr         = %cfg.node_addr,
        store_port   = cfg.store_port,
        api_port     = cfg.api_port,
        peers        = cfg.peers.len(),
        monitor_vms  = cfg.monitor_vms,
        "omega-daemon V4 démarré"
    );

    // ─── Composants partagés ──────────────────────────────────────────────

    let metrics = Arc::new(StoreMetrics::default());
    let store = Arc::new(PageStore::new(metrics.clone()));
    let vm_tracker = Arc::new(VmTracker::new(
        cfg.qemu_pid_dir.clone(),
        cfg.qemu_conf_dir.clone(),
    ));
    let num_pcpus = num_cpus::get();
    let gpu_runtime = initialize_gpu_runtime(&cfg).await;
    let node_state = Arc::new(NodeState::new(
        cfg.node_id.clone(),
        cfg.store_public_addr(),
        cfg.api_public_addr(),
        store.clone(),
        metrics.clone(),
        vm_tracker.clone(),
        num_pcpus,
        cfg.qemu_pid_dir.clone(),
        gpu_runtime.clone(),
    ));

    // ─── Tâche 1 : Store TCP ──────────────────────────────────────────────
    {
        let store = store.clone();
        let metrics = metrics.clone();
        let vm_tracker = vm_tracker.clone();
        let listen = cfg.store_addr();
        let max_pages = cfg.max_pages;
        let node_id = cfg.node_id.clone();

        tokio::spawn(async move {
            if let Err(e) =
                run_store_server(listen, store, metrics, vm_tracker, max_pages, node_id).await
            {
                error!(error = %e, "store TCP terminé avec erreur");
            }
        });
    }

    // ─── Tâche 2 : API HTTP cluster (/api/*) ─────────────────────────────
    {
        let state = node_state.clone();
        let api_addr = cfg.api_addr();

        tokio::spawn(async move {
            if let Err(e) = run_api_server(state, api_addr).await {
                error!(error = %e, "API cluster HTTP terminée avec erreur");
            }
        });
    }

    // ─── Tâche 3 : Canal de contrôle HTTP (/control/*) — fix L2 ──────────
    {
        let state = node_state.clone();
        let control_addr = format!("0.0.0.0:{}", cfg.api_port + 100); // port 9300

        tokio::spawn(async move {
            let app = build_control_router(state);
            let Ok(listener) = tokio::net::TcpListener::bind(&control_addr).await else {
                error!(addr = %control_addr, "impossible de démarrer le canal contrôle");
                return;
            };
            info!(addr = %control_addr, "canal de contrôle HTTP démarré");
            let _ = axum::serve(listener, app).await;
        });
    }

    // ─── Tâche 4 : Découverte des VMs locales (périodique) ───────────────
    if cfg.monitor_vms {
        let tracker = vm_tracker.clone();
        let interval = Duration::from_secs(15);

        tokio::spawn(async move {
            info!("monitoring VMs locales actif (intervalle 15s)");
            loop {
                if let Err(e) = tracker.refresh_local_vms() {
                    warn!(error = %e, "refresh VMs échoué");
                }
                tokio::time::sleep(interval).await;
            }
        });
    }

    // ─── Tâche 4b : Monitoring CPU local + hotplug réel ─────────────────
    if cfg.monitor_vms {
        let state = node_state.clone();
        let tracker = vm_tracker.clone();
        let interval = Duration::from_millis(cfg.cpu_monitor_interval_ms.max(100));
        let qmp_dir = cfg.qemu_pid_dir.clone();
        let qemu_conf_dir = cfg.qemu_conf_dir.clone();

        tokio::spawn(async move {
            let cpu_ctrl = CgroupCpuController::new();
            let hotplug = VcpuHotplugManager::new(qmp_dir);
            let mut previous: HashMap<u32, (VmCpuStat, Instant)> = HashMap::new();

            info!(
                interval_ms = interval.as_millis() as u64,
                "monitoring CPU local actif"
            );

            loop {
                let local_vms = tracker.local_running_vms_snapshot();
                let local_ids: HashSet<u32> = local_vms.iter().map(|vm| vm.vmid).collect();

                for vm_state in state.vcpu_scheduler.vm_snapshot() {
                    if !local_ids.contains(&vm_state.vm_id) {
                        state.vcpu_scheduler.release_vm(vm_state.vm_id);
                    }
                }

                for vm in &local_vms {
                    ensure_vm_registered(&state, &hotplug, &cpu_ctrl, &qemu_conf_dir, vm.vmid);

                    let now = Instant::now();
                    if let Some(stat) = cpu_ctrl.read_cpu_stat(vm.vmid) {
                        if let Some((before, started_at)) = previous.get(&vm.vmid) {
                            let elapsed = started_at.elapsed().as_micros() as u64;
                            let usage_pct =
                                CgroupCpuController::compute_usage_pct(before, &stat, elapsed);
                            state.vcpu_scheduler.update_from_cgroup(
                                vm.vmid,
                                usage_pct,
                                stat.throttle_ratio(),
                            );
                        }
                        previous.insert(vm.vmid, (stat, now));
                    }
                }

                for vm_id in state.vcpu_scheduler.vms_needing_hotplug() {
                    apply_hotplug_if_possible(&state, &hotplug, &cpu_ctrl, vm_id);
                }

                for vm_id in state.vcpu_scheduler.vms_needing_downscale() {
                    apply_downscale_if_idle(&state, &hotplug, &cpu_ctrl, vm_id, false);
                }

                for (vm_id, reason) in state.vcpu_scheduler.vms_needing_migration() {
                    warn!(vm_id, reason = %reason, "VM candidate à la migration CPU");
                }

                tokio::time::sleep(interval).await;
            }
        });
    }

    // ─── Tâche 5 : Moteur d'éviction CLOCK + FaultBus (L1) ───────────────
    {
        // Créer le FaultBus — les handlers uffd posteront leurs événements ici
        let mut fault_bus = FaultBus::new(4096);

        // Publier l'émetteur dans NodeState pour que les handlers uffd y accèdent
        // (en V5 : stocké dans NodeState ; en V4 : exposé via variable statique)
        let _fault_sender = fault_bus.sender(); // utilisé par node-a-agent

        let consumer = FaultBusConsumer::new(
            fault_bus.take_receiver().unwrap(),
            10,  // fenêtre 10 secondes
            5.0, // accélération si > 5 fautes/sec
        );

        let engine = EvictionEngine::new(node_state.clone(), &cfg).with_fault_bus(consumer);

        tokio::spawn(engine.run());
    }

    // ─── Initialisation TLS (L3) ─────────────────────────────────────────
    {
        let tls_paths = TlsPaths::new("/etc/omega-store/tls");
        match TlsContext::generate_or_load(tls_paths, &cfg.node_id) {
            Ok(ctx) => {
                info!(
                    fingerprint = %ctx.fingerprint,
                    "TLS initialisé — empreinte à distribuer aux pairs pour TOFU"
                );
            }
            Err(e) => {
                warn!(error = %e, "TLS non disponible — canal de paging non chiffré");
            }
        }
    }

    // ─── Tâche 6 : Balloon Monitor — V4 ──────────────────────────────────
    if cfg.monitor_vms {
        let _qmp_dir = cfg.qemu_pid_dir.replace("qemu-server", "qemu-server"); // même dossier
        let vm_tracker_ref = vm_tracker.clone();
        let _threshold = cfg.evict_threshold_pct;

        // Le monitor balloon tourne dans un thread dédié (read QMP = bloquant)
        tokio::task::spawn_blocking(move || {
            // Découverte initiale des vmids locaux
            let vmids: Vec<u32> = vm_tracker_ref
                .local_vms_snapshot()
                .iter()
                .map(|vm| vm.vmid)
                .collect();

            if vmids.is_empty() {
                info!("aucune VM locale — balloon monitor en attente");
                // On laisse le thread tourner, il se relancera quand des VMs apparaissent
                std::thread::sleep(Duration::from_secs(60));
                return;
            }

            let monitor = BalloonMonitor::new(
                // On utilise le répertoire QMP standard Proxmox
                "/var/run/qemu-server".to_string(),
                15,   // poll toutes les 15s
                20.0, // alerte si RAM libre guest < 20%
                move |vmid: u32, stats: BalloonStats| {
                    warn!(
                        vmid,
                        free_pct = format!("{:.1}%", stats.free_pct()),
                        total_mib = stats.total_bytes / 1024 / 1024,
                        major_faults = stats.major_faults,
                        "BALLOON : pression mémoire guest → éviction accélérée recommandée"
                    );
                    // En V4 : le controller lira cet état via /api/status et décidera
                    // En V5 : déclencher directement l'éviction CLOCK
                },
            );
            monitor.run_blocking(vmids);
        });
    }

    // ─── Tâche 7 : Stats périodiques ─────────────────────────────────────
    {
        let state = node_state.clone();
        let interval = cfg.stats_interval;
        let node_id = cfg.node_id.clone();

        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(Duration::from_secs(interval));
            ticker.tick().await;
            loop {
                ticker.tick().await;
                let snap = state.snapshot();
                info!(
                    node_id           = %node_id,
                    mem_usage_pct     = format!("{:.1}%", snap.mem_usage_pct),
                    mem_available_mib = snap.mem_available_kb / 1024,
                    pages_stored      = snap.pages_stored,
                    store_used_mib    = snap.store_used_kb / 1024,
                    local_vms         = snap.local_vms.len(),
                    "stats périodiques"
                );
                for vm in &snap.local_vms {
                    if vm.remote_pages > 0 {
                        warn!(
                            vmid = vm.vmid,
                            remote_pages = vm.remote_pages,
                            remote_mib = vm.remote_mem_mib,
                            "VM avec pages distantes → candidat migration"
                        );
                    }
                }
            }
        });
    }

    // ─── Attente SIGTERM / SIGINT ─────────────────────────────────────────
    info!("daemon opérationnel — CTRL+C pour arrêter");
    tokio::signal::ctrl_c().await?;
    info!("signal d'arrêt reçu");
    Ok(())
}

fn setup_logging(cfg: &Config) {
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
}

async fn initialize_gpu_runtime(cfg: &Config) -> Option<Arc<GpuRuntime>> {
    if !cfg.gpu_enabled {
        info!("GPU désactivé par configuration");
        return None;
    }

    let backend_result = if cfg.gpu_render_node.trim().is_empty() {
        DrmGpuBackend::open_default()
    } else {
        DrmGpuBackend::open(std::path::Path::new(&cfg.gpu_render_node)).map(Arc::new)
    };

    let backend = match backend_result {
        Ok(backend) => backend,
        Err(e) => {
            warn!(error = %e, "GPU indisponible — multiplexeur désactivé");
            return None;
        }
    };

    let total_vram_mib = if cfg.gpu_total_vram_mib > 0 {
        cfg.gpu_total_vram_mib
    } else {
        backend.total_vram_mib()
    };

    let render_node = Some(backend.render_node().display().to_string());
    let backend_name = backend.name().to_string();
    let backend_trait: Arc<dyn GpuBackend> = backend;
    let mux = Arc::new(GpuMultiplexer::new(
        std::path::PathBuf::from(&cfg.gpu_socket_path),
        backend_trait,
    ));
    let runtime = Arc::new(GpuRuntime::new(
        Arc::clone(&mux),
        backend_name,
        render_node,
        cfg.gpu_socket_path.clone(),
        total_vram_mib,
    ));

    tokio::spawn({
        let mux = Arc::clone(&mux);
        async move {
            if let Err(e) = mux.run().await {
                error!(error = %e, "multiplexeur GPU terminé avec erreur");
            }
        }
    });

    info!(
        socket = %cfg.gpu_socket_path,
        total_vram_mib,
        "multiplexeur GPU initialisé"
    );

    Some(runtime)
}

fn ensure_vm_registered(
    state: &Arc<NodeState>,
    hotplug: &VcpuHotplugManager,
    cpu_ctrl: &CgroupCpuController,
    conf_dir: &str,
    vm_id: u32,
) {
    if state.vcpu_scheduler.has_vm(vm_id) {
        return;
    }

    let qmp_vcpus = hotplug.vcpu_info(vm_id);
    let online_vcpus = qmp_vcpus
        .as_ref()
        .map(|info| info.online_count.max(1))
        .unwrap_or(1);

    let (conf_min_vcpus, conf_max_vcpus) = read_vm_cpu_profile(conf_dir, vm_id).unwrap_or((1, 1));
    let min_vcpus = online_vcpus.max(conf_min_vcpus).max(1);
    let max_vcpus = qmp_vcpus
        .map(|info| info.total_count.max(conf_max_vcpus).max(min_vcpus))
        .unwrap_or(conf_max_vcpus.max(min_vcpus));

    match state.vcpu_scheduler.admit_vm(vm_id, min_vcpus, max_vcpus) {
        omega_daemon::vcpu_scheduler::VcpuDecision::Allocated { .. } => {
            let _ = cpu_ctrl.apply(&VmCpuConfig::new(vm_id).capped_at_vcpus(min_vcpus));
            info!(
                vm_id,
                min_vcpus, max_vcpus, "VM enregistrée automatiquement dans le scheduler vCPU"
            );
        }
        omega_daemon::vcpu_scheduler::VcpuDecision::MigrateRequired { reason, .. } => {
            warn!(
                vm_id,
                reason, "VM locale non enregistrée dans le scheduler vCPU faute de capacité"
            );
        }
        _ => {}
    }
}

fn read_vm_cpu_profile(conf_dir: &str, vm_id: u32) -> Option<(usize, usize)> {
    let conf_file = format!("{}/{}.conf", conf_dir, vm_id);
    let content = fs::read_to_string(conf_file).ok()?;

    let mut sockets = 1usize;
    let mut cores = 1usize;
    let mut boot_vcpus: Option<usize> = None;

    for line in content.lines() {
        if let Some(rest) = line.strip_prefix("sockets:") {
            sockets = rest.trim().parse::<usize>().ok().filter(|v| *v > 0).unwrap_or(1);
        } else if let Some(rest) = line.strip_prefix("cores:") {
            cores = rest.trim().parse::<usize>().ok().filter(|v| *v > 0).unwrap_or(1);
        } else if let Some(rest) = line.strip_prefix("vcpus:") {
            boot_vcpus = rest.trim().parse::<usize>().ok().filter(|v| *v > 0);
        }
    }

    let max_vcpus = sockets.saturating_mul(cores).max(1);
    let min_vcpus = boot_vcpus.unwrap_or(max_vcpus).clamp(1, max_vcpus);
    Some((min_vcpus, max_vcpus))
}

fn apply_hotplug_if_possible(
    state: &Arc<NodeState>,
    hotplug: &VcpuHotplugManager,
    cpu_ctrl: &CgroupCpuController,
    vm_id: u32,
) {
    use omega_daemon::vcpu_scheduler::VcpuDecision;

    let decision = state.vcpu_scheduler.try_hotplug(vm_id);
    let VcpuDecision::Hotplugged {
        new_count, slot, ..
    } = decision
    else {
        return;
    };

    let Some(vm_state) = state.vcpu_scheduler.get_vm_state(vm_id) else {
        return;
    };

    match hotplug.add_vcpu(vm_id, vm_state.min_vcpus, vm_state.max_vcpus) {
        HotplugResult::Added {
            new_count: qmp_count,
        } => {
            if let Err(e) = cpu_ctrl.apply(&VmCpuConfig::new(vm_id).capped_at_vcpus(qmp_count)) {
                warn!(vm_id, error = %e, "échec mise à jour cpu.max après hotplug");
            }
            info!(
                vm_id,
                scheduler_count = new_count,
                qmp_count,
                "hotplug vCPU appliqué automatiquement"
            );
        }
        HotplugResult::NoSlots { current, max } => {
            state.vcpu_scheduler.rollback_hotplug(vm_id, slot);
            warn!(
                vm_id,
                current, max, "hotplug QMP impossible — rollback scheduler, migration nécessaire"
            );
        }
        HotplugResult::Unavailable { reason } => {
            state.vcpu_scheduler.rollback_hotplug(vm_id, slot);
            warn!(
                vm_id,
                reason, "hotplug QMP indisponible — rollback scheduler"
            );
        }
        HotplugResult::Removed { .. } | HotplugResult::AtMin { .. } => {
            state.vcpu_scheduler.rollback_hotplug(vm_id, slot);
        }
    }
}

fn apply_downscale_if_idle(
    state: &Arc<NodeState>,
    hotplug: &VcpuHotplugManager,
    cpu_ctrl: &CgroupCpuController,
    vm_id: u32,
    force: bool,
) {
    use omega_daemon::vcpu_scheduler::VcpuDecision;

    let decision = state.vcpu_scheduler.try_downscale(vm_id, force);
    let VcpuDecision::Downscaled {
        new_count, slot, ..
    } = decision
    else {
        return;
    };

    let Some(vm_state) = state.vcpu_scheduler.get_vm_state(vm_id) else {
        let _ = state.vcpu_scheduler.rollback_downscale(vm_id, slot);
        return;
    };

    match hotplug.remove_vcpu(vm_id, vm_state.min_vcpus) {
        HotplugResult::Removed { new_count: qmp_count } => {
            if let Err(e) = cpu_ctrl.apply(&VmCpuConfig::new(vm_id).capped_at_vcpus(qmp_count)) {
                warn!(vm_id, error = %e, "échec mise à jour cpu.max après hot-unplug");
            }
            info!(
                vm_id,
                scheduler_count = new_count,
                qmp_count,
                force,
                "downscale vCPU appliqué automatiquement"
            );
        }
        HotplugResult::AtMin { .. } => {
            let _ = state.vcpu_scheduler.rollback_downscale(vm_id, slot);
        }
        HotplugResult::Unavailable { reason } => {
            let _ = state.vcpu_scheduler.rollback_downscale(vm_id, slot);
            warn!(vm_id, reason, "hot-unplug QMP indisponible — rollback scheduler");
        }
        HotplugResult::NoSlots { .. } | HotplugResult::Added { .. } => {
            let _ = state.vcpu_scheduler.rollback_downscale(vm_id, slot);
            warn!(vm_id, "résultat QMP inattendu pendant hot-unplug");
        }
    }
}
