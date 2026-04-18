//! Point d'entrée du store de pages distantes.
//!
//! Usage :
//!   node-bc-store --listen 0.0.0.0:9100 --node-id node-b
//!   node-bc-store --listen 0.0.0.0:9101 --node-id node-c

use anyhow::Result;
use clap::Parser;
use tracing_subscriber::{EnvFilter, fmt};

use node_bc_store::config::Config;
use node_bc_store::server;

#[tokio::main]
async fn main() -> Result<()> {
    let cfg = Config::parse();

    // Initialisation du système de logs
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new(&cfg.log_level));

    match cfg.log_format.as_str() {
        "json" => {
            fmt()
                .json()
                .with_env_filter(filter)
                .with_current_span(false)
                .init();
        }
        _ => {
            fmt()
                .with_env_filter(filter)
                .with_target(false)
                .init();
        }
    }

    server::run(cfg).await
}
