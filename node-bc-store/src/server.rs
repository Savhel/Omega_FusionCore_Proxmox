//! Serveur TCP asynchrone.
//!
//! Une tâche Tokio par connexion client. Le `PageStore` et les `StoreMetrics`
//! sont partagés via `Arc` — aucune copie, pas de verrou global.

use std::net::SocketAddr;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use tokio::net::{TcpListener, TcpStream};
use tokio::time;
use tracing::{debug, error, info, warn};

use crate::config::Config;
use crate::metrics::StoreMetrics;
use crate::protocol::{Message, Opcode};
use crate::store::{PageKey, PageStore};

/// Point d'entrée du serveur.
///
/// Lance le listener TCP et la tâche périodique de stats,
/// puis dispatche chaque connexion dans sa propre tâche Tokio.
pub async fn run(cfg: Config) -> Result<()> {
    let listener = TcpListener::bind(&cfg.listen).await?;
    info!(
        node_id = %cfg.node_id,
        listen  = %cfg.listen,
        "store démarré"
    );

    let metrics = Arc::new(StoreMetrics::default());
    let store = Arc::new(PageStore::new(metrics.clone()));

    // Tâche d'affichage périodique des métriques
    {
        let metrics = metrics.clone();
        let interval = cfg.stats_interval;
        let node_id = cfg.node_id.clone();
        tokio::spawn(async move {
            let mut ticker = time::interval(Duration::from_secs(interval));
            ticker.tick().await; // skip du premier tick immédiat
            loop {
                ticker.tick().await;
                let snap = metrics.snapshot();
                info!(
                    node_id       = %node_id,
                    pages         = snap.pages_stored,
                    bytes         = snap.estimated_bytes,
                    puts          = snap.put_count,
                    gets          = snap.get_count,
                    hits          = snap.hit_count,
                    misses        = snap.miss_count,
                    hit_rate_pct  = snap.hit_rate_pct,
                    connections   = snap.active_connections,
                    "stats périodiques"
                );
            }
        });
    }

    loop {
        let (stream, peer) = listener.accept().await?;
        let store = store.clone();
        let metrics = metrics.clone();
        let max_pages = cfg.max_pages;
        let node_id = cfg.node_id.clone();

        metrics.connections.fetch_add(1, Ordering::Relaxed);
        info!(peer = %peer, "nouvelle connexion");

        tokio::spawn(async move {
            if let Err(e) =
                handle_connection(stream, peer, store, metrics.clone(), max_pages, &node_id).await
            {
                // Erreurs de connexion fermée (EOF) sont normales → debug seulement
                if is_connection_reset(&e) {
                    debug!(peer = %peer, "connexion fermée par le client");
                } else {
                    warn!(peer = %peer, error = %e, "erreur connexion");
                }
            }
            metrics.connections.fetch_sub(1, Ordering::Relaxed);
            debug!(peer = %peer, "connexion terminée");
        });
    }
}

/// Gère une connexion client : boucle de lecture/réponse des messages.
async fn handle_connection(
    mut stream: TcpStream,
    peer: SocketAddr,
    store: Arc<PageStore>,
    _metrics: Arc<StoreMetrics>,
    max_pages: u64,
    node_id: &str,
) -> Result<()> {
    // Split en deux moitiés pour lire et écrire sans conflit de borrow
    let (mut reader, mut writer) = stream.split();

    loop {
        let msg = match Message::read_from(&mut reader).await {
            Ok(m) => m,
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(()),
            Err(e) => return Err(e.into()),
        };

        debug!(
            peer    = %peer,
            opcode  = ?msg.opcode,
            vm_id   = msg.vm_id,
            page_id = msg.page_id,
            "message reçu"
        );

        let response = dispatch(&msg, &store, max_pages, node_id);

        if let Err(e) = response.write_to(&mut writer).await {
            error!(peer = %peer, error = %e, "erreur écriture réponse");
            return Err(e.into());
        }
    }
}

/// Dispatch d'un message vers l'opération correspondante.
///
/// Retourne toujours un `Message` de réponse, même en cas d'erreur métier
/// (erreur réseau → propagée en `Err`).
fn dispatch(msg: &Message, store: &Arc<PageStore>, max_pages: u64, node_id: &str) -> Message {
    match msg.opcode {
        Opcode::Ping => Message::pong(),

        Opcode::PutPage => {
            // Vérification limite de capacité
            if max_pages > 0 && store.len() as u64 >= max_pages {
                return Message::error_msg("store plein : limite max_pages atteinte");
            }

            let key = PageKey::new(msg.vm_id, msg.page_id);
            match store.put(key, msg.payload.clone()) {
                Ok(_) => Message::ok(msg.vm_id, msg.page_id),
                Err(err) => Message::error_msg(&err),
            }
        }

        Opcode::GetPage => {
            let key = PageKey::new(msg.vm_id, msg.page_id);
            match store.get(&key) {
                Some(data) => Message::new(Opcode::Ok, msg.vm_id, msg.page_id, data),
                None => Message::not_found(msg.vm_id, msg.page_id),
            }
        }

        Opcode::DeletePage => {
            let key = PageKey::new(msg.vm_id, msg.page_id);
            if store.delete(&key) {
                Message::ok(msg.vm_id, msg.page_id)
            } else {
                Message::not_found(msg.vm_id, msg.page_id)
            }
        }

        Opcode::StatsRequest => {
            let snap = store.estimated_bytes(); // taille brute
            let metrics_snap = {
                // On reconstruit depuis le store (les métriques sont dans StoreMetrics)
                // On sérialise un objet compact
                let json = serde_json::json!({
                    "node_id":        node_id,
                    "pages_stored":   store.len(),
                    "estimated_bytes": snap,
                });
                json.to_string()
            };
            Message::stats_response(metrics_snap)
        }

        // Ces opcodes sont des réponses, pas des requêtes : protocole invalide
        op => {
            warn!(opcode = ?op, "opcode réponse reçu côté serveur — protocole invalide");
            Message::error_msg("opcode inattendu côté serveur")
        }
    }
}

/// Détecte les erreurs de connexion réinitialisée / fermée (log debug, pas warn).
fn is_connection_reset(e: &anyhow::Error) -> bool {
    if let Some(io_err) = e.downcast_ref::<std::io::Error>() {
        matches!(
            io_err.kind(),
            std::io::ErrorKind::ConnectionReset
                | std::io::ErrorKind::BrokenPipe
                | std::io::ErrorKind::UnexpectedEof
        )
    } else {
        false
    }
}
