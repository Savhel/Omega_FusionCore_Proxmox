//! API HTTP du cluster — exposée par chaque nœud via axum.
//!
//! # Endpoints
//!
//! ```text
//! GET  /api/status          → NodeStatus JSON (RAM, VMs, pages, etc.)
//! GET  /api/pages           → [{vmid, pages_stored}] pour ce nœud
//! GET  /api/health          → {"ok": true}
//! DELETE /api/pages/{vmid}  → supprime toutes les pages d'une VM (post-migration)
//! ```
//!
//! Ces endpoints sont consommés par le `omega-controller` Python pour construire
//! l'état global du cluster et prendre des décisions de migration.

use std::sync::Arc;

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::Json,
    routing::{delete, get},
    Router,
};
use serde_json::{json, Value};
use tracing::info;

use crate::node_state::NodeState;
use node_bc_store::store::PageKey;

/// Construit le routeur axum.
pub fn build_router(state: Arc<NodeState>) -> Router {
    Router::new()
        .route("/api/health", get(health))
        .route("/api/status", get(node_status))
        .route("/api/pages", get(pages_list))
        .route("/api/pages/:vmid", delete(delete_vm_pages))
        .with_state(state)
}

/// Lance le serveur HTTP sur l'adresse configurée.
pub async fn run_api_server(state: Arc<NodeState>, addr: String) -> anyhow::Result<()> {
    let app = build_router(state);
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    info!(addr = %addr, "API HTTP cluster démarrée");
    axum::serve(listener, app).await?;
    Ok(())
}

// ─── Handlers ─────────────────────────────────────────────────────────────────

/// GET /api/health — vérification de vie minimale
async fn health() -> Json<Value> {
    Json(json!({"ok": true, "version": env!("CARGO_PKG_VERSION")}))
}

/// GET /api/status — état complet du nœud
async fn node_status(State(state): State<Arc<NodeState>>) -> Json<Value> {
    let snap = state.snapshot();
    Json(serde_json::to_value(snap).unwrap_or_else(|_| json!({"error": "serialization"})))
}

/// GET /api/pages — pages stockées sur ce nœud, par vm_id
async fn pages_list(State(state): State<Arc<NodeState>>) -> Json<Value> {
    let pages = state.pages_per_vm();
    let entries: Vec<Value> = pages
        .iter()
        .map(|(vmid, count)| {
            json!({
                "vmid":         vmid,
                "pages_stored": count,
                "mem_kb":       count * 4,
            })
        })
        .collect();
    Json(json!({"pages": entries, "node_id": state.node_id}))
}

/// DELETE /api/pages/{vmid} — supprime toutes les pages d'une VM
///
/// Appelé par le controller après une migration réussie pour libérer la mémoire
/// du store qui n'est plus utile (la VM est maintenant sur un autre nœud avec
/// toute sa RAM locale).
async fn delete_vm_pages(
    State(state): State<Arc<NodeState>>,
    Path(vmid): Path<u32>,
) -> (StatusCode, Json<Value>) {
    // On parcourt le store et supprime toutes les pages de ce vm_id.
    // Le DashMap ne supporte pas de scan par préfixe directement —
    // on collecte les clés puis on supprime.
    let keys_to_delete: Vec<PageKey> = {
        // Reconstruction des clés à partir des page_ids connus via le tracker
        let _pages_count = state.vm_tracker.pages_stored_for(vmid);
        // Note: pour une suppression complète en V4, on itère les clés du store.
        // Le DashMap expose iter() pour ça.
        state.store.keys_for_vm(vmid)
    };

    let deleted = keys_to_delete.len();
    for key in keys_to_delete {
        state.store.delete(&key);
    }

    // Mise à jour du tracker
    state.vm_tracker.record_page_stored(vmid, -(deleted as i64));

    info!(vmid, deleted, "pages VM supprimées post-migration");

    (
        StatusCode::OK,
        Json(json!({
            "vmid":    vmid,
            "deleted": deleted,
            "node_id": state.node_id,
        })),
    )
}
