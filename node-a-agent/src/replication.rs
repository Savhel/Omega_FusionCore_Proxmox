//! Réplication des pages distantes — correction de la limite L3.
//!
//! # Stratégie de réplication V4
//!
//! Chaque page est écrite sur **deux stores** :
//! - **Primaire** : `page_id % num_stores`
//! - **Réplica**  : `(page_id + 1) % num_stores`
//!
//! Lors d'un GET_PAGE :
//! - On contacte d'abord le primaire
//! - Si le primaire échoue → on contacte le réplica (fallback)
//! - On journalise le fallback pour signaler au controller que le store primaire est dégradé
//!
//! # Impact sur les performances
//!
//! Chaque PUT_PAGE effectue 2 appels réseau séquentiels (ou parallèles en V5).
//! En V4, on fait les deux en séquence pour ne pas complexifier le modèle de
//! concurrence dans le thread uffd-handler.
//!
//! # Désactivation
//!
//! La réplication peut être désactivée si `num_stores < 2` ou si
//! `replication_factor = 1`. Dans ce cas, le comportement est identique à la V1.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::{bail, Result};
use tracing::{debug, warn};

use crate::remote::RemoteStorePool;
use node_bc_store::protocol::PAGE_SIZE;

/// Métriques de réplication.
#[derive(Default, Debug)]
pub struct ReplicationMetrics {
    pub primary_puts:    AtomicU64,
    pub replica_puts:    AtomicU64,
    pub primary_gets:    AtomicU64,
    pub replica_gets:    AtomicU64,   // GET depuis le réplica (fallback)
    pub primary_fails:   AtomicU64,   // PUT primaire échoué
    pub replica_fails:   AtomicU64,   // PUT réplica échoué
}

/// Client avec réplication.
///
/// Wraps `RemoteStorePool` et ajoute la logique d'écriture/lecture redondante.
pub struct ReplicatedStoreClient {
    pool:    Arc<RemoteStorePool>,
    metrics: Arc<ReplicationMetrics>,
    /// Facteur de réplication (1 = pas de réplication, 2 = un réplica)
    factor:  usize,
}

impl ReplicatedStoreClient {
    pub fn new(pool: Arc<RemoteStorePool>, factor: usize) -> Self {
        let factor = factor.min(pool.num_stores()).max(1);
        Self {
            pool,
            metrics: Arc::new(ReplicationMetrics::default()),
            factor,
        }
    }

    pub fn metrics(&self) -> Arc<ReplicationMetrics> {
        self.metrics.clone()
    }

    /// PUT_PAGE avec réplication.
    ///
    /// Écrit la page sur le store primaire et, si `factor >= 2`, sur le réplica.
    /// Retourne Ok si au moins le primaire a réussi.
    pub async fn put_page(&self, vm_id: u32, page_id: u64, data: Vec<u8>) -> Result<()> {
        if data.len() != PAGE_SIZE {
            bail!("put_page répliqué : taille incorrecte {}", data.len());
        }

        // Écriture primaire
        let primary_result = self.pool.put_page(vm_id, page_id, data.clone()).await;
        match &primary_result {
            Ok(_)  => {
                self.metrics.primary_puts.fetch_add(1, Ordering::Relaxed);
                debug!(vm_id, page_id, "PUT primaire ok");
            }
            Err(e) => {
                self.metrics.primary_fails.fetch_add(1, Ordering::Relaxed);
                warn!(vm_id, page_id, error = %e, "PUT primaire échoué");
            }
        }

        // Écriture réplica (si factor >= 2 et plus d'un store disponible)
        if self.factor >= 2 && self.pool.num_stores() >= 2 {
            let replica_result = self.pool.put_page_replica(vm_id, page_id, data).await;
            match replica_result {
                Ok(_)  => {
                    self.metrics.replica_puts.fetch_add(1, Ordering::Relaxed);
                    debug!(vm_id, page_id, "PUT réplica ok");
                }
                Err(e) => {
                    self.metrics.replica_fails.fetch_add(1, Ordering::Relaxed);
                    // Échec réplica non fatal — le primaire suffit
                    warn!(vm_id, page_id, error = %e, "PUT réplica échoué (non fatal)");
                }
            }
        }

        // On propage l'erreur primaire seulement si le primaire a échoué ET
        // qu'il n'y a pas de réplica disponible
        if primary_result.is_err() && (self.factor < 2 || self.pool.num_stores() < 2) {
            return primary_result;
        }

        Ok(())
    }

    /// GET_PAGE avec fallback vers le réplica.
    pub async fn get_page(&self, vm_id: u32, page_id: u64) -> Result<Option<Vec<u8>>> {
        self.metrics.primary_gets.fetch_add(1, Ordering::Relaxed);

        // Lecture primaire
        match self.pool.get_page(vm_id, page_id).await {
            Ok(Some(data)) => return Ok(Some(data)),
            Ok(None)       => {
                // Page absente du primaire — tenter le réplica avant de déclarer NOT_FOUND
            }
            Err(e) => {
                warn!(vm_id, page_id, error = %e, "GET primaire échoué — tentative réplica");
                self.metrics.primary_fails.fetch_add(1, Ordering::Relaxed);
            }
        }

        // Fallback réplica
        if self.factor >= 2 && self.pool.num_stores() >= 2 {
            self.metrics.replica_gets.fetch_add(1, Ordering::Relaxed);
            match self.pool.get_page_replica(vm_id, page_id).await {
                Ok(Some(data)) => {
                    warn!(vm_id, page_id, "GET servi depuis le réplica — store primaire dégradé ?");
                    return Ok(Some(data));
                }
                Ok(None) => {}
                Err(e)   => {
                    warn!(vm_id, page_id, error = %e, "GET réplica aussi échoué");
                }
            }
        }

        Ok(None)
    }

    /// DELETE_PAGE sur primaire + réplica.
    pub async fn delete_page(&self, vm_id: u32, page_id: u64) -> Result<bool> {
        let primary = self.pool.delete_page(vm_id, page_id).await?;
        if self.factor >= 2 && self.pool.num_stores() >= 2 {
            let _ = self.pool.delete_page_replica(vm_id, page_id).await;
        }
        Ok(primary)
    }
}
