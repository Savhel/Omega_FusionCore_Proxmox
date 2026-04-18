//! Configuration CLI de l'agent nœud A.

use clap::Parser;

#[derive(Parser, Debug, Clone)]
#[command(
    name       = "node-a-agent",
    about      = "Agent de paging mémoire distant — nœud A du cluster omega-remote-paging",
    version    = env!("CARGO_PKG_VERSION"),
    long_about = None,
)]
pub struct Config {
    /// Adresses des stores distants, format "ip:port", séparées par des virgules.
    /// Ex: "192.168.1.2:9100,192.168.1.3:9101"
    #[arg(
        long,
        default_value = "127.0.0.1:9100,127.0.0.1:9101",
        env = "AGENT_STORES",
        value_delimiter = ','
    )]
    pub stores: Vec<String>,

    /// Identifiant VM simulé (utilisé comme vm_id dans le protocole)
    #[arg(long, default_value_t = 1, env = "AGENT_VM_ID")]
    pub vm_id: u32,

    /// Taille de la région mémoire gérée par userfaultfd, en Mio
    #[arg(long, default_value_t = 64, env = "AGENT_REGION_MIB")]
    pub region_mib: usize,

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
}
