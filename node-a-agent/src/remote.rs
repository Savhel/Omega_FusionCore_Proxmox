//! Client TCP vers les stores distants (nœuds B et C).
//!
//! # Stratégie de routage
//!
//! La sélection du store cible est déterministe : `store_index = page_id % num_stores`.
//! Cela garantit qu'une page est toujours sur le même store, sans état supplémentaire.
//!
//! # Pool de connexions
//!
//! Chaque store dispose de `CONN_POOL_SIZE` connexions TCP persistantes.
//! Les requêtes sont distribuées en round-robin atomique sur ces connexions,
//! ce qui permet aux N workers uffd de faire des GET_PAGE **en parallèle**
//! sans se sérialiser sur un seul Mutex.
//!
//! Avant : 1 Mutex<StoreConn> par store  → N workers bloqués en série
//! Après : CONN_POOL_SIZE Mutex<StoreConn> par store → N workers s'étalent sur K connexions

use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use anyhow::{bail, Context, Result};
use tokio::io::BufStream;
use tokio::net::TcpStream;
use tokio::sync::Mutex;
use tokio::time::timeout;
use tracing::{debug, info, warn};

use node_bc_store::protocol::{BatchPutRequest, BatchPutResponse, Message, Opcode, PAGE_SIZE};

/// Nombre de connexions TCP maintenues par store.
/// 4 connexions parallèles couvrent largement un pool de workers uffd typique.
const CONN_POOL_SIZE: usize = 4;

// ─── Connexion individuelle ───────────────────────────────────────────────────

struct StoreConn {
    addr:    String,
    stream:  Option<BufStream<TcpStream>>,
    timeout: Duration,
}

impl StoreConn {
    fn new(addr: String, timeout: Duration) -> Self {
        Self { addr, stream: None, timeout }
    }

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

    fn disconnect(&mut self) {
        if self.stream.is_some() {
            warn!(addr = %self.addr, "connexion invalidée — reconnexion au prochain appel");
            self.stream = None;
        }
    }

    async fn send_recv(&mut self, req: Message) -> Result<Message> {
        self.ensure_connected().await?;
        let stream = self.stream.as_mut().unwrap();

        match timeout(self.timeout, req.write_to(stream)).await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => { self.disconnect(); return Err(e.into()); }
            Err(_)     => { self.disconnect(); bail!("timeout écriture vers store {}", self.addr); }
        }

        match timeout(self.timeout, Message::read_from(stream)).await {
            Ok(Ok(resp)) => Ok(resp),
            Ok(Err(e))   => { self.disconnect(); Err(e.into()) }
            Err(_)       => { self.disconnect(); bail!("timeout lecture depuis store {}", self.addr); }
        }
    }
}

// ─── Pool de connexions pour un store ────────────────────────────────────────

/// Pool de K connexions vers un même store, distribuées en round-robin.
struct ConnPool {
    conns: Vec<Mutex<StoreConn>>,
    next:  AtomicUsize,
}

impl ConnPool {
    fn new(addr: String, timeout: Duration, size: usize) -> Self {
        let conns = (0..size)
            .map(|_| Mutex::new(StoreConn::new(addr.clone(), timeout)))
            .collect();
        Self { conns, next: AtomicUsize::new(0) }
    }

    /// Sélectionne une connexion par round-robin et envoie la requête.
    async fn send_recv(&self, req: Message) -> Result<Message> {
        let idx = self.next.fetch_add(1, Ordering::Relaxed) % self.conns.len();
        self.conns[idx].lock().await.send_recv(req).await
    }

    /// Ping sur la première connexion du pool.
    async fn ping(&self) -> bool {
        self.conns[0]
            .lock()
            .await
            .send_recv(Message::ping())
            .await
            .map(|r| matches!(r.opcode, Opcode::Pong))
            .unwrap_or(false)
    }
}

// ─── RemoteStorePool ──────────────────────────────────────────────────────────

/// Pool de connexions vers les N stores (B et C).
///
/// Partagé via `Arc<RemoteStorePool>` entre les workers uffd et le thread principal.
/// Chaque store dispose de `CONN_POOL_SIZE` connexions parallèles.
pub struct RemoteStorePool {
    stores: Vec<ConnPool>,
}

impl RemoteStorePool {
    pub fn new(addrs: Vec<String>, timeout_ms: u64) -> Self {
        let t = Duration::from_millis(timeout_ms);
        let stores = addrs
            .into_iter()
            .map(|addr| ConnPool::new(addr, t, CONN_POOL_SIZE))
            .collect();
        Self { stores }
    }

    fn store_index(&self, page_id: u64) -> usize {
        (page_id as usize) % self.stores.len()
    }

    fn replica_index(&self, page_id: u64) -> usize {
        (self.store_index(page_id) + 1) % self.stores.len()
    }

    pub async fn put_page(&self, vm_id: u32, page_id: u64, data: Vec<u8>) -> Result<()> {
        if data.len() != PAGE_SIZE {
            bail!("put_page : taille incorrecte {} (attendu {})", data.len(), PAGE_SIZE);
        }
        let idx  = self.store_index(page_id);
        let base = Message::put_page(vm_id, page_id, data);
        // Compression LZ4 transparente : envoie la version compressée si elle est plus courte
        let req  = base.try_compress().unwrap_or(base);
        let resp = self.stores[idx]
            .send_recv(req)
            .await
            .with_context(|| format!("PUT_PAGE vm={vm_id} page={page_id} vers store[{idx}]"))?;

        match resp.opcode {
            Opcode::Ok    => { debug!(vm_id, page_id, store_idx = idx, "PUT_PAGE ok"); Ok(()) }
            Opcode::Error => { let m = String::from_utf8_lossy(&resp.payload); bail!("PUT_PAGE refusé : {m}") }
            op            => bail!("PUT_PAGE réponse inattendue : {op:?}"),
        }
    }

    pub async fn get_page(&self, vm_id: u32, page_id: u64) -> Result<Option<Vec<u8>>> {
        let idx  = self.store_index(page_id);
        let req  = Message::get_page(vm_id, page_id);
        let resp = self.stores[idx]
            .send_recv(req)
            .await
            .with_context(|| format!("GET_PAGE vm={vm_id} page={page_id} depuis store[{idx}]"))?;

        match resp.opcode {
            Opcode::Ok => {
                if resp.payload.len() != PAGE_SIZE {
                    bail!("GET_PAGE : réponse taille incorrecte {}", resp.payload.len());
                }
                debug!(vm_id, page_id, store_idx = idx, "GET_PAGE hit");
                Ok(Some(resp.payload))
            }
            Opcode::NotFound => { debug!(vm_id, page_id, store_idx = idx, "GET_PAGE miss"); Ok(None) }
            Opcode::Error    => { let m = String::from_utf8_lossy(&resp.payload); bail!("GET_PAGE erreur store : {m}") }
            op               => bail!("GET_PAGE réponse inattendue : {op:?}"),
        }
    }

    pub async fn delete_page(&self, vm_id: u32, page_id: u64) -> Result<bool> {
        let idx  = self.store_index(page_id);
        let req  = Message::delete_page(vm_id, page_id);
        let resp = self.stores[idx]
            .send_recv(req)
            .await
            .with_context(|| format!("DELETE_PAGE vm={vm_id} page={page_id}"))?;

        match resp.opcode {
            Opcode::Ok       => Ok(true),
            Opcode::NotFound => Ok(false),
            Opcode::Error    => { let m = String::from_utf8_lossy(&resp.payload); bail!("DELETE_PAGE erreur : {m}") }
            op               => bail!("DELETE_PAGE réponse inattendue : {op:?}"),
        }
    }

    /// Envoie N pages en une seule trame BATCH_PUT, groupées par store.
    ///
    /// Pour un lot de 16 pages evictées, remplace 16 RTT par 1 RTT par store.
    /// Le payload batch est aussi compressé LZ4 si rentable.
    pub async fn batch_put_pages(
        &self,
        vm_id:  u32,
        pages:  Vec<(u64, Vec<u8>)>,
    ) -> Result<u32> {
        if pages.is_empty() { return Ok(0); }

        // Grouper les pages par store cible
        let mut by_store: Vec<Vec<(u64, Vec<u8>)>> = vec![Vec::new(); self.stores.len()];
        for (pid, data) in pages {
            by_store[self.store_index(pid)].push((pid, data));
        }

        let mut total_stored = 0u32;
        for (idx, store_pages) in by_store.into_iter().enumerate() {
            if store_pages.is_empty() { continue; }

            let mut req = BatchPutRequest::new(vm_id);
            for (pid, data) in store_pages {
                req.push(pid, data);
            }

            // Utilise une connexion dédiée du pool pour le batch entier
            let slot_idx = self.stores[idx].next.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
                % self.stores[idx].conns.len();
            let mut conn = self.stores[idx].conns[slot_idx].lock().await;
            conn.ensure_connected().await?;

            // Phase écriture — le borrow de `stream` se termine à la fin du bloc
            let write_result = {
                let stream = conn.stream.as_mut().unwrap();
                req.write_to(stream).await
            };
            if let Err(e) = write_result {
                conn.stream = None;
                return Err(e.into());
            }

            // Phase lecture — nouveau borrow de `stream`
            let read_result = {
                let stream = conn.stream.as_mut().unwrap();
                BatchPutResponse::read_from(stream).await
            };
            let resp = match read_result {
                Ok(r)  => r,
                Err(e) => { conn.stream = None; return Err(e.into()); }
            };

            total_stored += resp.stored;
            debug!(vm_id, store_idx = idx, stored = resp.stored, failed = resp.failed, "BATCH_PUT ok");
        }

        Ok(total_stored)
    }

    pub async fn put_page_replica(&self, vm_id: u32, page_id: u64, data: Vec<u8>) -> Result<()> {
        let idx  = self.replica_index(page_id);
        let base = Message::put_page(vm_id, page_id, data.clone());
        let req  = base.try_compress().unwrap_or(base);
        let resp = self.stores[idx]
            .send_recv(req)
            .await
            .with_context(|| format!("PUT_PAGE_REPLICA vm={vm_id} page={page_id} vers store[{idx}]"))?;

        match resp.opcode {
            Opcode::Ok    => Ok(()),
            Opcode::Error => { let m = String::from_utf8_lossy(&resp.payload); bail!("PUT réplica refusé : {m}") }
            op            => bail!("PUT réplica réponse inattendue : {op:?}"),
        }
    }

    pub async fn get_page_replica(&self, vm_id: u32, page_id: u64) -> Result<Option<Vec<u8>>> {
        let idx  = self.replica_index(page_id);
        let req  = Message::get_page(vm_id, page_id);
        let resp = self.stores[idx]
            .send_recv(req)
            .await
            .with_context(|| format!("GET_PAGE_REPLICA vm={vm_id} page={page_id} depuis store[{idx}]"))?;

        match resp.opcode {
            Opcode::Ok       => Ok(Some(resp.payload)),
            Opcode::NotFound => Ok(None),
            Opcode::Error    => { let m = String::from_utf8_lossy(&resp.payload); bail!("GET réplica erreur : {m}") }
            op               => bail!("GET réplica réponse inattendue : {op:?}"),
        }
    }

    pub async fn delete_page_replica(&self, vm_id: u32, page_id: u64) -> Result<bool> {
        let idx  = self.replica_index(page_id);
        let req  = Message::delete_page(vm_id, page_id);
        let resp = self.stores[idx]
            .send_recv(req)
            .await
            .with_context(|| format!("DELETE_PAGE_REPLICA vm={vm_id} page={page_id}"))?;

        match resp.opcode {
            Opcode::Ok       => Ok(true),
            Opcode::NotFound => Ok(false),
            op               => bail!("DELETE réplica réponse inattendue : {op:?}"),
        }
    }

    pub async fn ping_all(&self) -> Vec<(usize, bool)> {
        let mut results = Vec::new();
        for (idx, pool) in self.stores.iter().enumerate() {
            results.push((idx, pool.ping().await));
        }
        results
    }

    pub fn num_stores(&self) -> usize {
        self.stores.len()
    }
}
