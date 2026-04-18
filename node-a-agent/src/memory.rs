//! Gestion de la région mémoire paginée distante.
//!
//! # Cycle de vie d'une page
//!
//! ```text
//! État PRÉSENTE  ──evict()──►  État DISTANTE
//!      ▲                           │
//!      └─────── fault_handler() ───┘
//!               (via UFFDIO_COPY)
//! ```
//!
//! Une page est `DISTANTE` après `evict_page()` :
//!   1. On lit ses 4096 octets depuis la région locale.
//!   2. On les envoie au store via PUT_PAGE.
//!   3. On appelle `madvise(MADV_DONTNEED)` → le kernel libère la page physique.
//!   4. La page entre dans le suivi `remote_pages` (BitVec simplifié ici).
//!
//! Au prochain accès, userfaultfd intercepte la faute (UFFD_EVENT_PAGEFAULT),
//! et le handler appelle `fetch_page()` → GET_PAGE → UFFDIO_COPY.

use std::collections::HashSet;
use std::sync::Arc;

use anyhow::{bail, Context, Result};
use tokio::runtime::Handle;
use tracing::{debug, info, warn};

use crate::metrics::AgentMetrics;
use crate::remote::RemoteStorePool;

pub const PAGE_SIZE: usize = 4096;

/// Région mémoire anonyme mmap, enregistrée auprès d'userfaultfd.
///
/// Partageable entre threads via `Arc<MemoryRegion>` (les seuls accès mutables
/// passent par unsafe avec discipline explicite).
pub struct MemoryRegion {
    pub base:       *mut u8,
    pub size:       usize,
    pub num_pages:  usize,
    pub vm_id:      u32,

    /// Pages actuellement externalisées sur un store distant.
    /// Protégé par un Mutex pour accès concurrent handler/main.
    remote_pages:   std::sync::Mutex<HashSet<u64>>,

    store:          Arc<RemoteStorePool>,
    metrics:        Arc<AgentMetrics>,
    tokio_handle:   Handle,
}

// SAFETY: base est un pointeur vers une région mmap propre à ce processus.
// L'accès concurrent est contrôlé : le thread uffd ne lit que les pages
// présentes (pas remotées), et les opérations d'éviction sont sérialisées
// via le HashSet protégé par Mutex.
unsafe impl Send for MemoryRegion {}
unsafe impl Sync for MemoryRegion {}

impl MemoryRegion {
    /// Alloue une région mmap anonyme de `size_bytes` octets.
    ///
    /// La région est PROT_READ|PROT_WRITE mais non encore peuplée.
    pub fn allocate(
        size_bytes:   usize,
        vm_id:        u32,
        store:        Arc<RemoteStorePool>,
        metrics:      Arc<AgentMetrics>,
        tokio_handle: Handle,
    ) -> Result<Self> {
        assert!(size_bytes.is_multiple_of(PAGE_SIZE), "size_bytes doit être multiple de PAGE_SIZE");

        // SAFETY: mmap standard avec MAP_ANONYMOUS|MAP_PRIVATE.
        let base = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                size_bytes,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_PRIVATE | libc::MAP_ANONYMOUS,
                -1,
                0,
            )
        };

        if base == libc::MAP_FAILED {
            let err = std::io::Error::last_os_error();
            bail!("mmap({} Mio) échoué : {err}", size_bytes / 1024 / 1024);
        }

        let num_pages = size_bytes / PAGE_SIZE;
        info!(
            base       = format!("{:p}", base),
            size_bytes = size_bytes,
            num_pages  = num_pages,
            "région mémoire allouée"
        );

        Ok(Self {
            base:         base as *mut u8,
            size:         size_bytes,
            num_pages,
            vm_id,
            remote_pages: std::sync::Mutex::new(HashSet::new()),
            store,
            metrics,
            tokio_handle,
        })
    }

    /// Pointeur vers le début de la page `page_id` dans la région locale.
    fn page_ptr(&self, page_id: u64) -> *mut u8 {
        // SAFETY: page_id < num_pages garanti par l'appelant.
        unsafe { self.base.add(page_id as usize * PAGE_SIZE) }
    }

    /// Écrit `data` dans la page locale `page_id` (bypass uffd — page déjà présente).
    pub fn write_page_local(&self, page_id: u64, data: &[u8; PAGE_SIZE]) -> Result<()> {
        if page_id >= self.num_pages as u64 {
            bail!("page_id {} hors limites (max {})", page_id, self.num_pages - 1);
        }
        // SAFETY: ptr valide, data valide, pas d'aliasing concurrent sur cette page.
        unsafe {
            std::ptr::copy_nonoverlapping(data.as_ptr(), self.page_ptr(page_id), PAGE_SIZE);
        }
        Ok(())
    }

    /// Lit les 4096 octets de la page locale `page_id`.
    pub fn read_page_local(&self, page_id: u64) -> Result<[u8; PAGE_SIZE]> {
        if page_id >= self.num_pages as u64 {
            bail!("page_id {} hors limites", page_id);
        }
        let mut buf = [0u8; PAGE_SIZE];
        // SAFETY: ptr valide, buf valide.
        unsafe {
            std::ptr::copy_nonoverlapping(self.page_ptr(page_id), buf.as_mut_ptr(), PAGE_SIZE);
        }
        Ok(buf)
    }

    /// Évince la page `page_id` vers le store distant.
    ///
    /// Séquence :
    ///   1. Lecture des 4096 octets locaux.
    ///   2. PUT_PAGE vers le store.
    ///   3. `madvise(MADV_DONTNEED)` → libère la page physique.
    ///   4. Marquage comme `remote`.
    pub fn evict_page(&self, page_id: u64) -> Result<()> {
        if page_id >= self.num_pages as u64 {
            bail!("evict_page : page_id {} hors limites", page_id);
        }

        {
            let remote = self.remote_pages.lock().unwrap();
            if remote.contains(&page_id) {
                debug!(page_id, "page déjà distante — éviction ignorée");
                return Ok(());
            }
        }

        // 1. Lecture locale
        let data = self.read_page_local(page_id)?;

        // 2. Envoi au store (synchrone via block_on depuis le thread courant)
        let vm_id = self.vm_id;
        let store = self.store.clone();
        self.tokio_handle
            .block_on(store.put_page(vm_id, page_id, data.to_vec()))
            .with_context(|| format!("evict_page : PUT_PAGE page={page_id} échoué"))?;

        // 3. Libération locale (MADV_DONTNEED → page devient "missing" → uffd interceptera)
        let ptr = self.page_ptr(page_id);
        // SAFETY: ptr valide, PAGE_SIZE correct.
        let ret = unsafe { libc::madvise(ptr as *mut libc::c_void, PAGE_SIZE, libc::MADV_DONTNEED) };
        if ret != 0 {
            let err = std::io::Error::last_os_error();
            warn!(page_id, error = %err, "madvise(MADV_DONTNEED) échoué — page non libérée");
        }

        // 4. Marquage
        self.remote_pages.lock().unwrap().insert(page_id);
        self.metrics.pages_evicted.fetch_add(1, std::sync::atomic::Ordering::Relaxed);

        debug!(page_id, "page évinvée vers store");
        Ok(())
    }

    /// Récupère une page depuis le store distant et la rend disponible.
    ///
    /// Appelé par le handler userfaultfd. Retourne les 4096 octets à injecter.
    pub fn fetch_page(&self, page_id: u64) -> Result<[u8; PAGE_SIZE]> {
        let vm_id = self.vm_id;
        let store = self.store.clone();

        let data = self.tokio_handle
            .block_on(store.get_page(vm_id, page_id))
            .with_context(|| format!("fetch_page : GET_PAGE page={page_id} échoué"))?;

        match data {
            Some(bytes) => {
                let mut arr = [0u8; PAGE_SIZE];
                arr.copy_from_slice(&bytes);

                // Démarquer comme distant (la page va être réinsérée localement par UFFDIO_COPY)
                self.remote_pages.lock().unwrap().remove(&page_id);
                self.metrics.pages_fetched.fetch_add(1, std::sync::atomic::Ordering::Relaxed);

                Ok(arr)
            }
            None => {
                // Page absente du store : on retourne une page zéro
                // (situation anormale — possible si store redémarré)
                warn!(page_id, "page absente du store — page zéro retournée");
                self.metrics.fetch_zeros.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                Ok([0u8; PAGE_SIZE])
            }
        }
    }

    /// Retourne le pointeur base de la région (pour l'enregistrement uffd).
    pub fn base_ptr(&self) -> *mut libc::c_void {
        self.base as *mut libc::c_void
    }

    pub fn is_remote(&self, page_id: u64) -> bool {
        self.remote_pages.lock().unwrap().contains(&page_id)
    }

    pub fn remote_count(&self) -> usize {
        self.remote_pages.lock().unwrap().len()
    }
}

impl Drop for MemoryRegion {
    fn drop(&mut self) {
        // SAFETY: base/size valides, libération propre.
        unsafe {
            libc::munmap(self.base as *mut libc::c_void, self.size);
        }
        info!("région mémoire libérée");
    }
}
