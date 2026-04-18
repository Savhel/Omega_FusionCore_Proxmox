//! Client TCP vers les stores distants (nœuds B et C).
//!
//! # Stratégie de routage (V1)
//!
//! La sélection du store cible est déterministe : `store_index = page_id % num_stores`.
//! Cela garantit qu'une page est toujours sur le même store, sans état supplémentaire.
//!
//! # Connexions
//!
//! Pour simplifier la V1 : une connexion TCP par store, persistante (reconnexion automatique
//! si le store est temporairement indisponible). En V2 : pool de connexions.

use std::time::Duration;

use anyhow::{bail, Context, Result};
use tokio::io::BufStream;
use tokio::net::TcpStream;
use tokio::sync::Mutex;
use tokio::time::timeout;
use tracing::{debug, info, warn};

use node_bc_store::protocol::{Message, Opcode, PAGE_SIZE};

/// Une connexion persistante vers un store.
struct StoreConn {
    addr:    String,
    stream:  Option<BufStream<TcpStream>>,
    timeout: Duration,
}

impl StoreConn {
    fn new(addr: String, timeout: Duration) -> Self {
        Self { addr, stream: None, timeout }
    }

    /// Assure qu'une connexion TCP est établie (reconnexion automatique).
    async fn ensure_connected(&mut self) -> Result<()> {
        if self.stream.is_some() {
            return Ok(());
        }

        debug!(addr = %self.addr, "connexion au store");
        let tcp = timeout(self.timeout, TcpStream::connect(&self.addr))
            .await
            .context("timeout connexion store")?
            .with_context(|| format!("connexion TCP vers {} échouée", self.addr))?;

        tcp.set_nodelay(true)?;
        self.stream = Some(BufStream::new(tcp));
        info!(addr = %self.addr, "connecté au store");
        Ok(())
    }

    /// Invalide la connexion (sera réouverte au prochain appel).
    fn disconnect(&mut self) {
        if self.stream.is_some() {
            warn!(addr = %self.addr, "connexion au store invalidée (reconnexion au prochain appel)");
            self.stream = None;
        }
    }

    /// Envoie une requête et lit la réponse.
    ///
    /// Si une erreur réseau survient, la connexion est invalidée pour forcer
    /// une reconnexion au prochain appel.
    async fn send_recv(&mut self, req: Message) -> Result<Message> {
        self.ensure_connected().await?;

        let stream = self.stream.as_mut().unwrap();

        let write_result = timeout(self.timeout, req.write_to(stream)).await;
        match write_result {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                self.disconnect();
                return Err(e.into());
            }
            Err(_) => {
                self.disconnect();
                bail!("timeout écriture vers store {}", self.addr);
            }
        }

        let read_result = timeout(self.timeout, Message::read_from(stream)).await;
        match read_result {
            Ok(Ok(resp)) => Ok(resp),
            Ok(Err(e))   => {
                self.disconnect();
                Err(e.into())
            }
            Err(_) => {
                self.disconnect();
                bail!("timeout lecture depuis store {}", self.addr);
            }
        }
    }
}

// ---------------------------------------------------------------------------------
// RemoteStorePool
// ---------------------------------------------------------------------------------

/// Pool de connexions vers les N stores (B et C).
///
/// Partagé via `Arc<RemoteStorePool>` entre le thread uffd-handler et le thread
/// principal (pour les opérations d'éviction).
pub struct RemoteStorePool {
    stores: Vec<Mutex<StoreConn>>,
}

impl RemoteStorePool {
    pub fn new(addrs: Vec<String>, timeout_ms: u64) -> Self {
        let t = Duration::from_millis(timeout_ms);
        let stores = addrs
            .into_iter()
            .map(|addr| Mutex::new(StoreConn::new(addr, t)))
            .collect();
        Self { stores }
    }

    /// Retourne l'index du store responsable de `page_id`.
    fn store_index(&self, page_id: u64) -> usize {
        (page_id as usize) % self.stores.len()
    }

    /// Envoie une page vers le store approprié (PUT_PAGE).
    pub async fn put_page(&self, vm_id: u32, page_id: u64, data: Vec<u8>) -> Result<()> {
        if data.len() != PAGE_SIZE {
            bail!("put_page : taille incorrecte {} (attendu {})", data.len(), PAGE_SIZE);
        }

        let idx = self.store_index(page_id);
        let req = Message::put_page(vm_id, page_id, data);
        let resp = self.stores[idx].lock().await.send_recv(req).await
            .with_context(|| format!("PUT_PAGE vm={vm_id} page={page_id} vers store[{idx}]"))?;

        match resp.opcode {
            Opcode::Ok => {
                debug!(vm_id, page_id, store_idx = idx, "PUT_PAGE ok");
                Ok(())
            }
            Opcode::Error => {
                let msg = String::from_utf8_lossy(&resp.payload);
                bail!("PUT_PAGE refusé par le store : {msg}");
            }
            op => bail!("PUT_PAGE réponse inattendue : {op:?}"),
        }
    }

    /// Récupère une page depuis le store approprié (GET_PAGE).
    ///
    /// Retourne `None` si la page n'existe pas sur le store.
    pub async fn get_page(&self, vm_id: u32, page_id: u64) -> Result<Option<Vec<u8>>> {
        let idx = self.store_index(page_id);
        let req = Message::get_page(vm_id, page_id);
        let resp = self.stores[idx].lock().await.send_recv(req).await
            .with_context(|| format!("GET_PAGE vm={vm_id} page={page_id} depuis store[{idx}]"))?;

        match resp.opcode {
            Opcode::Ok => {
                if resp.payload.len() != PAGE_SIZE {
                    bail!("GET_PAGE : réponse avec taille incorrecte {}", resp.payload.len());
                }
                debug!(vm_id, page_id, store_idx = idx, "GET_PAGE hit");
                Ok(Some(resp.payload))
            }
            Opcode::NotFound => {
                debug!(vm_id, page_id, store_idx = idx, "GET_PAGE miss");
                Ok(None)
            }
            Opcode::Error => {
                let msg = String::from_utf8_lossy(&resp.payload);
                bail!("GET_PAGE erreur store : {msg}");
            }
            op => bail!("GET_PAGE réponse inattendue : {op:?}"),
        }
    }

    /// Supprime une page du store (DELETE_PAGE).
    pub async fn delete_page(&self, vm_id: u32, page_id: u64) -> Result<bool> {
        let idx = self.store_index(page_id);
        let req = Message::delete_page(vm_id, page_id);
        let resp = self.stores[idx].lock().await.send_recv(req).await
            .with_context(|| format!("DELETE_PAGE vm={vm_id} page={page_id}"))?;

        match resp.opcode {
            Opcode::Ok       => Ok(true),
            Opcode::NotFound => Ok(false),
            Opcode::Error    => {
                let msg = String::from_utf8_lossy(&resp.payload);
                bail!("DELETE_PAGE erreur store : {msg}");
            }
            op => bail!("DELETE_PAGE réponse inattendue : {op:?}"),
        }
    }

    /// Index du store réplica pour `page_id` (store suivant dans l'anneau).
    fn replica_index(&self, page_id: u64) -> usize {
        (self.store_index(page_id) + 1) % self.stores.len()
    }

    /// PUT_PAGE vers le store réplica (index suivant dans l'anneau).
    pub async fn put_page_replica(&self, vm_id: u32, page_id: u64, data: Vec<u8>) -> Result<()> {
        let idx = self.replica_index(page_id);
        let req = Message::put_page(vm_id, page_id, data);
        let resp = self.stores[idx].lock().await.send_recv(req).await
            .with_context(|| format!("PUT_PAGE_REPLICA vm={vm_id} page={page_id} vers store[{idx}]"))?;
        match resp.opcode {
            Opcode::Ok    => Ok(()),
            Opcode::Error => {
                let msg = String::from_utf8_lossy(&resp.payload);
                bail!("PUT_PAGE réplica refusé : {msg}");
            }
            op => bail!("PUT_PAGE réplica réponse inattendue : {op:?}"),
        }
    }

    /// GET_PAGE depuis le store réplica (fallback).
    pub async fn get_page_replica(&self, vm_id: u32, page_id: u64) -> Result<Option<Vec<u8>>> {
        let idx = self.replica_index(page_id);
        let req = Message::get_page(vm_id, page_id);
        let resp = self.stores[idx].lock().await.send_recv(req).await
            .with_context(|| format!("GET_PAGE_REPLICA vm={vm_id} page={page_id} depuis store[{idx}]"))?;
        match resp.opcode {
            Opcode::Ok       => Ok(Some(resp.payload)),
            Opcode::NotFound => Ok(None),
            Opcode::Error    => {
                let msg = String::from_utf8_lossy(&resp.payload);
                bail!("GET_PAGE réplica erreur : {msg}");
            }
            op => bail!("GET_PAGE réplica réponse inattendue : {op:?}"),
        }
    }

    /// DELETE_PAGE sur le store réplica.
    pub async fn delete_page_replica(&self, vm_id: u32, page_id: u64) -> Result<bool> {
        let idx = self.replica_index(page_id);
        let req = Message::delete_page(vm_id, page_id);
        let resp = self.stores[idx].lock().await.send_recv(req).await
            .with_context(|| format!("DELETE_PAGE_REPLICA vm={vm_id} page={page_id}"))?;
        match resp.opcode {
            Opcode::Ok       => Ok(true),
            Opcode::NotFound => Ok(false),
            op => bail!("DELETE_PAGE réplica réponse inattendue : {op:?}"),
        }
    }

    /// Ping vers tous les stores — vérifie la connectivité.
    pub async fn ping_all(&self) -> Vec<(usize, bool)> {
        let mut results = Vec::new();
        for (idx, store) in self.stores.iter().enumerate() {
            let ok = store.lock().await
                .send_recv(Message::ping())
                .await
                .map(|r| matches!(r.opcode, Opcode::Pong))
                .unwrap_or(false);
            results.push((idx, ok));
        }
        results
    }

    pub fn num_stores(&self) -> usize {
        self.stores.len()
    }
}
