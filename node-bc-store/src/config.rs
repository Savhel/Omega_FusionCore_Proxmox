//! Configuration CLI du store.

use clap::Parser;

#[derive(Parser, Debug, Clone)]
#[command(
    name        = "node-bc-store",
    about       = "Store de pages mémoire distantes — nœuds B/C du cluster omega-remote-paging",
    version     = env!("CARGO_PKG_VERSION"),
    long_about  = None,
)]
pub struct Config {
    /// Adresse d'écoute TCP (IP:port)
    #[arg(long, default_value = "0.0.0.0:9100", env = "STORE_LISTEN")]
    pub listen: String,

    /// Identifiant du nœud (ex: "node-b", "node-c") — utilisé dans les logs
    #[arg(long, default_value = "node-store", env = "STORE_NODE_ID")]
    pub node_id: String,

    /// Limite maximale de pages stockées (0 = illimité)
    #[arg(long, default_value_t = 0, env = "STORE_MAX_PAGES")]
    pub max_pages: u64,

    /// Format de log : "text" ou "json"
    #[arg(long, default_value = "text", env = "STORE_LOG_FORMAT")]
    pub log_format: String,

    /// Niveau de log (RUST_LOG syntax)
    #[arg(long, default_value = "info", env = "RUST_LOG")]
    pub log_level: String,

    /// Intervalle (secondes) d'affichage des stats périodiques
    #[arg(long, default_value_t = 30, env = "STORE_STATS_INTERVAL")]
    pub stats_interval: u64,
}
