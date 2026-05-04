//! Configuration CLI de l'agent nœud A.

use std::path::PathBuf;

use clap::Parser;

#[derive(Parser, Debug, Clone)]
#[command(
    name       = "node-a-agent",
    about      = "Agent de paging mémoire distant — nœud A du cluster omega-remote-paging",
    version    = env!("CARGO_PKG_VERSION"),
    long_about = None,
)]
pub struct Config {
    // ─── Stores TCP ──────────────────────────────────────────────────────────

    /// Adresses TCP des stores distants (parallel à --status-addrs), format "ip:port".
    #[arg(
        long,
        default_value = "127.0.0.1:9100,127.0.0.1:9101",
        env           = "AGENT_STORES",
        value_delimiter = ','
    )]
    pub stores: Vec<String>,

    /// Adresses HTTP des serveurs status cluster (parallel à --stores), format "ip:port".
    /// Ex: "10.10.0.12:9200,10.10.0.13:9200"
    #[arg(
        long,
        default_value = "",
        env           = "AGENT_STATUS_ADDRS",
        value_delimiter = ','
    )]
    pub status_addrs: Vec<String>,

    // ─── VM ──────────────────────────────────────────────────────────────────

    /// Identifiant VM (vmid Proxmox)
    #[arg(long, default_value_t = 1, env = "AGENT_VM_ID")]
    pub vm_id: u32,

    /// RAM totale demandée par la VM dans sa config Proxmox, en Mio.
    /// Plafond absolu de pages à gérer (local + distant).
    #[arg(long, default_value_t = 2048, env = "AGENT_VM_REQUESTED_MIB")]
    pub vm_requested_mib: u64,

    /// Taille de la région mémoire gérée par userfaultfd, en Mio.
    /// Doit être ≥ vm_requested_mib.
    #[arg(long, default_value_t = 2048, env = "AGENT_REGION_MIB")]
    pub region_mib: usize,

    // ─── Backend mémoire ─────────────────────────────────────────────────────

    /// Backend mémoire local : `anonymous` ou `memfd`.
    #[arg(long, default_value = "anonymous", env = "AGENT_BACKEND")]
    pub backend: String,

    /// Nom logique du memfd quand `--backend memfd` est utilisé.
    #[arg(
        long,
        default_value = "omega-qemu-remote-memory",
        env = "AGENT_MEMFD_NAME"
    )]
    pub memfd_name: String,

    /// Fichier JSON optionnel où écrire les métadonnées de partage du backend.
    #[arg(long, env = "AGENT_EXPORT_METADATA")]
    pub export_metadata: Option<PathBuf>,

    // ─── Éviction ────────────────────────────────────────────────────────────

    /// Seuil de RAM disponible sur ce nœud (en Mio) sous lequel l'éviction se déclenche.
    /// 0 = désactivé.
    #[arg(long, default_value_t = 512, env = "AGENT_EVICTION_THRESHOLD_MIB")]
    pub eviction_threshold_mib: u64,

    /// Nombre de pages à évincer par tick.
    #[arg(long, default_value_t = 64, env = "AGENT_EVICTION_BATCH_SIZE")]
    pub eviction_batch_size: usize,

    /// Intervalle en secondes entre deux vérifications d'éviction.
    #[arg(long, default_value_t = 5, env = "AGENT_EVICTION_INTERVAL_SECS")]
    pub eviction_interval_secs: u64,

    // ─── Rappel (recall LIFO) ─────────────────────────────────────────────────

    /// Seuil de RAM disponible (en Mio) au-dessus duquel le rappel de pages se déclenche.
    /// Le recall commence quand le nœud a de nouveau de la place.
    #[arg(long, default_value_t = 1024, env = "AGENT_RECALL_THRESHOLD_MIB")]
    pub recall_threshold_mib: u64,

    /// Nombre de pages à rappeler par tick.
    #[arg(long, default_value_t = 32, env = "AGENT_RECALL_BATCH_SIZE")]
    pub recall_batch_size: usize,

    /// Intervalle en secondes entre deux vérifications de recall.
    #[arg(long, default_value_t = 10, env = "AGENT_RECALL_INTERVAL_SECS")]
    pub recall_interval_secs: u64,

    // ─── Migration ───────────────────────────────────────────────────────────

    /// Activer la recherche de migration dès qu'une VM commence à souffrir.
    #[arg(long, default_value_t = false, env = "AGENT_MIGRATION_ENABLED")]
    pub migration_enabled: bool,

    /// Nom du nœud Proxmox courant (ex: "pve1") — utilisé pour cibler la migration.
    #[arg(long, default_value = "pve1", env = "AGENT_CURRENT_NODE")]
    pub current_node: String,

    /// Intervalle en secondes entre deux recherches de nœud candidat pour migration.
    #[arg(long, default_value_t = 30, env = "AGENT_MIGRATION_INTERVAL_SECS")]
    pub migration_interval_secs: u64,

    /// Activer la compaction du cluster (déplacer d'autres VMs pour créer de la place).
    #[arg(long, default_value_t = false, env = "AGENT_COMPACTION_ENABLED")]
    pub compaction_enabled: bool,

    /// Nombre de vCPUs max de la VM (demandé à la création Proxmox).
    /// Sert aussi de plafond pour le scheduler élastique et de critère de migration.
    #[arg(long, default_value_t = 1, env = "AGENT_VM_VCPUS")]
    pub vm_vcpus: u32,

    /// vCPUs actifs au démarrage de la VM (≤ vm_vcpus).
    /// Le scheduler élastique les augmente au fur et à mesure de la demande.
    #[arg(long, default_value_t = 1, env = "AGENT_VM_INITIAL_VCPUS")]
    pub vm_initial_vcpus: u32,

    /// Utilisation vCPU (%) au-dessus de laquelle on scale-up.
    #[arg(long, default_value_t = 75, env = "AGENT_VCPU_HIGH_THRESHOLD_PCT")]
    pub vcpu_high_threshold_pct: u32,

    /// Utilisation vCPU (%) en-dessous de laquelle on scale-down.
    #[arg(long, default_value_t = 25, env = "AGENT_VCPU_LOW_THRESHOLD_PCT")]
    pub vcpu_low_threshold_pct: u32,

    /// Intervalle en secondes entre deux mesures d'utilisation vCPU.
    #[arg(long, default_value_t = 30, env = "AGENT_VCPU_SCALE_INTERVAL_SECS")]
    pub vcpu_scale_interval_secs: u64,

    /// Ratio d'overcommit vCPU : 1 cœur physique = N vCPUs (défaut 3).
    #[arg(long, default_value_t = 3, env = "AGENT_VCPU_OVERCOMMIT_RATIO")]
    pub vcpu_overcommit_ratio: u32,

    /// RAM minimale requise sur le nœud cible pour accepter la migration, en Mio.
    /// 0 = utiliser eviction_threshold_mib comme plancher.
    #[arg(long, default_value_t = 0, env = "AGENT_VM_MIN_RAM_MIB")]
    pub vm_min_ram_mib: u64,

    /// Nombre de VMs qui tournent sur ce nœud (hint pour la politique de recall équitable).
    /// Chaque VM se voit allouer recall_batch_size / vm_count_hint pages par tick.
    #[arg(long, default_value_t = 1, env = "AGENT_VM_COUNT_HINT")]
    pub vm_count_hint: usize,

    /// Priorité de recall (1 = basse, 10 = haute).
    /// Les VMs à faible priorité attendent plus longtemps avant de rappeler des pages.
    #[arg(long, default_value_t = 5, env = "AGENT_RECALL_PRIORITY")]
    pub recall_priority: u32,

    // ─── Cluster status refresh ───────────────────────────────────────────────

    /// Intervalle en secondes entre deux rafraîchissements du statut cluster.
    #[arg(long, default_value_t = 15, env = "AGENT_CLUSTER_REFRESH_SECS")]
    pub cluster_refresh_secs: u64,

    // ─── Logs ────────────────────────────────────────────────────────────────

    /// Format de log : "text" ou "json"
    #[arg(long, default_value = "text", env = "AGENT_LOG_FORMAT")]
    pub log_format: String,

    /// Niveau de log
    #[arg(long, default_value = "info", env = "RUST_LOG")]
    pub log_level: String,

    /// Timeout TCP vers les stores, en millisecondes
    #[arg(long, default_value_t = 2000, env = "AGENT_STORE_TIMEOUT_MS")]
    pub store_timeout_ms: u64,

    /// Mode : "demo" (scénario de test interne) ou "daemon" (attend des signaux)
    #[arg(long, default_value = "demo", env = "AGENT_MODE")]
    pub mode: String,

    // ─── GPU ─────────────────────────────────────────────────────────────────

    /// La VM nécessite un accès GPU.
    /// Si true, le démon de placement GPU cherche un nœud avec GPU et migre si besoin.
    #[arg(long, default_value_t = false, env = "AGENT_GPU_REQUIRED")]
    pub gpu_required: bool,

    /// Intervalle en secondes entre deux tentatives de placement GPU.
    #[arg(long, default_value_t = 60, env = "AGENT_GPU_PLACEMENT_INTERVAL_SECS")]
    pub gpu_placement_interval_secs: u64,

    /// Quantum de temps GPU par VM pour le scheduler de partage (secondes).
    /// Chaque VM GPU reçoit le GPU pendant ce temps avant de céder sa place.
    #[arg(long, default_value_t = 30, env = "AGENT_GPU_QUANTUM_SECS")]
    pub gpu_quantum_secs: u64,

    // ─── Réplication ─────────────────────────────────────────────────────────

    /// Activer la réplication write-through des pages vers le store suivant.
    /// En cas de panne du store primaire, le recall bascule automatiquement sur le replica.
    #[arg(long, default_value_t = false, env = "AGENT_REPLICATION_ENABLED")]
    pub replication_enabled: bool,

    // ─── TLS ─────────────────────────────────────────────────────────────────

    /// Empreintes SHA-256 (hex) des stores de confiance, séparées par des virgules.
    /// Si vide, TLS est désactivé (canal en clair). Exemple :
    ///   AGENT_TLS_FINGERPRINTS=ab12cd34ef56...,ff00aa11bb22...
    #[arg(long, default_value = "", env = "AGENT_TLS_FINGERPRINTS")]
    pub tls_fingerprints: String,

    // ─── Métriques ────────────────────────────────────────────────────────────

    /// Adresse d'écoute du serveur HTTP de métriques.
    #[arg(long, default_value = "0.0.0.0:9300", env = "AGENT_METRICS_LISTEN")]
    pub metrics_listen: String,

}
