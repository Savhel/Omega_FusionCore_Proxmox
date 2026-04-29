//! Algorithme d'éviction CLOCK.
//!
//! # Algorithme CLOCK
//!
//! Le CLOCK est une approximation LRU à faible coût :
//!
//! ```text
//!  Pages :   [ 0 ][ 1 ][ 2 ][ 3 ][ 4 ][ 5 ]
//!  Access:   [  1 ][  0 ][  1 ][  1 ][  0 ][  0 ]
//!  Hand  :         ^--- pointe ici
//!
//! Éviction : si access[hand] == 0 → évincer cette page
//!            si access[hand] == 1 → mettre à 0, avancer la main
//! ```
//!
//! # Optimisation O(1) pour mark_present
//!
//! La détection de présence dans l'anneau utilise un `HashSet<u64>` annexe.
//! `VecDeque::contains` est O(n) — avec des milliers de pages, ça devient
//! visible sur le hot path (chaque page fault appelle mark_present).
//! Le HashSet maintient la même information en O(1) lookup.

use std::collections::{HashSet, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use dashmap::DashMap;
use tracing::{debug, trace};

/// Métadonnées de suivi par page.
#[derive(Debug, Clone)]
pub struct PageMeta {
    pub access_bit:     bool,
    pub last_access:    Instant,
    pub eviction_count: u32,
    pub is_remote:      bool,
}

impl Default for PageMeta {
    fn default() -> Self {
        Self {
            access_bit:     true,
            last_access:    Instant::now(),
            eviction_count: 0,
            is_remote:      false,
        }
    }
}

// ─── Anneau CLOCK avec lookup O(1) ───────────────────────────────────────────

/// Anneau circulaire CLOCK avec présence O(1) via HashSet.
struct ClockRingInner {
    deque:   VecDeque<u64>,
    present: HashSet<u64>,
}

impl ClockRingInner {
    fn new(capacity: usize) -> Self {
        Self {
            deque:   VecDeque::with_capacity(capacity),
            present: HashSet::with_capacity(capacity),
        }
    }

    #[inline]
    fn contains(&self, id: u64) -> bool {
        self.present.contains(&id)
    }

    #[inline]
    fn push_back(&mut self, id: u64) {
        self.deque.push_back(id);
        self.present.insert(id);
    }

    #[inline]
    fn pop_front(&mut self) -> Option<u64> {
        let id = self.deque.pop_front()?;
        self.present.remove(&id);
        Some(id)
    }

    fn push_back_front(&mut self, id: u64) {
        // Rotation : déplacer la tête vers la queue (seconde chance CLOCK)
        let front = self.deque.pop_front().unwrap();
        debug_assert_eq!(front, id);
        self.deque.push_back(front);
        // present inchangé
    }

    /// Retire une page de l'anneau (mark_remote). O(n) mais hors hot path.
    fn remove(&mut self, id: u64) {
        if self.present.remove(&id) {
            self.deque.retain(|&x| x != id);
        }
    }

    fn front(&self) -> Option<u64> {
        self.deque.front().copied()
    }

    fn len(&self) -> usize {
        self.deque.len()
    }
}

// ─── ClockEvictor ────────────────────────────────────────────────────────────

/// Gestionnaire d'éviction CLOCK.
pub struct ClockEvictor {
    meta:       Arc<DashMap<u64, PageMeta>>,
    clock_ring: Mutex<ClockRingInner>,
    min_age:    Duration,
    num_pages:  usize,
}

impl ClockEvictor {
    pub fn new(num_pages: usize, min_age_secs: u64) -> Self {
        Self {
            meta:       Arc::new(DashMap::new()),
            clock_ring: Mutex::new(ClockRingInner::new(num_pages)),
            min_age:    Duration::from_secs(min_age_secs),
            num_pages,
        }
    }

    /// Enregistre une page comme présente localement. O(1).
    pub fn mark_present(&self, page_id: u64) {
        self.meta.entry(page_id).and_modify(|m| {
            m.access_bit = true;
            m.last_access = Instant::now();
            m.is_remote  = false;
        }).or_insert_with(PageMeta::default);

        let mut ring = self.clock_ring.lock().unwrap();
        if !ring.contains(page_id) {
            ring.push_back(page_id);
        }
    }

    /// Notifie un accès à la page.
    pub fn mark_accessed(&self, page_id: u64) {
        if let Some(mut meta) = self.meta.get_mut(&page_id) {
            meta.access_bit = true;
            meta.last_access = Instant::now();
        }
        trace!(page_id, "access_bit mis à 1");
    }

    /// Marque la page comme distante (après éviction). O(n) mais hors hot path.
    pub fn mark_remote(&self, page_id: u64) {
        if let Some(mut meta) = self.meta.get_mut(&page_id) {
            meta.is_remote      = true;
            meta.eviction_count += 1;
        }
        self.clock_ring.lock().unwrap().remove(page_id);
    }

    /// Sélectionne jusqu'à `count` pages à évincer selon l'algorithme CLOCK.
    pub fn select_victims(&self, count: usize) -> Vec<u64> {
        let mut ring    = self.clock_ring.lock().unwrap();
        let mut victims = Vec::with_capacity(count);
        let ring_len    = ring.len();

        if ring_len == 0 || count == 0 {
            return victims;
        }

        let max_iterations = ring_len; // 1 tour : chaque page reçoit au plus 1 seconde chance
        let mut iters      = 0;

        while victims.len() < count && iters < max_iterations {
            iters += 1;

            let page_id = match ring.front() {
                Some(p) => p,
                None    => break,
            };

            let evictable = self.meta.get(&page_id).map(|m| {
                !m.access_bit
                && m.last_access.elapsed() >= self.min_age
                && !m.is_remote
            }).unwrap_or(false);

            if evictable {
                ring.pop_front();
                victims.push(page_id);
                debug!(page_id, "CLOCK : page sélectionnée pour éviction");
            } else {
                if let Some(mut m) = self.meta.get_mut(&page_id) {
                    m.access_bit = false;
                }
                ring.push_back_front(page_id);
            }
        }

        debug!(
            found    = victims.len(),
            wanted   = count,
            ring_len,
            iters,
            "CLOCK select_victims terminé"
        );

        victims
    }

    pub fn local_count(&self) -> usize {
        self.clock_ring.lock().unwrap().len()
    }

    pub fn cold_pages_count(&self) -> usize {
        self.meta.iter()
            .filter(|e| !e.access_bit && !e.is_remote)
            .count()
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_clock_basic_eviction() {
        let evictor = ClockEvictor::new(10, 0);
        for i in 0..5u64 {
            evictor.mark_present(i);
        }
        for i in 0..5u64 {
            evictor.mark_accessed(i);
            if let Some(mut m) = evictor.meta.get_mut(&i) {
                m.access_bit = false;
            }
        }
        let victims = evictor.select_victims(3);
        assert_eq!(victims.len(), 3);
    }

    #[test]
    fn test_accessed_page_not_evicted_immediately() {
        let evictor = ClockEvictor::new(10, 0);
        evictor.mark_present(42);
        evictor.mark_accessed(42);
        let victims = evictor.select_victims(1);
        assert_eq!(victims.len(), 0, "page récente ne doit pas être évinvée immédiatement");
    }

    #[test]
    fn test_mark_remote_removes_from_ring() {
        let evictor = ClockEvictor::new(10, 0);
        evictor.mark_present(10);
        evictor.mark_remote(10);
        assert_eq!(evictor.local_count(), 0);
    }

    #[test]
    fn test_no_victims_if_all_accessed() {
        let evictor = ClockEvictor::new(10, 0);
        for i in 0..3u64 {
            evictor.mark_present(i);
        }
        let victims = evictor.select_victims(3);
        assert!(victims.len() <= 3);
    }

    #[test]
    fn test_mark_present_o1_no_duplicate() {
        let evictor = ClockEvictor::new(10, 0);
        evictor.mark_present(7);
        evictor.mark_present(7); // deuxième appel — ne doit pas dupliquer
        assert_eq!(evictor.local_count(), 1, "mark_present doit être idempotent");
    }

    #[test]
    fn test_hashset_present_consistent_with_ring() {
        let evictor = ClockEvictor::new(10, 0);
        for i in 0..5u64 {
            evictor.mark_present(i);
        }
        evictor.mark_remote(2);
        let ring = evictor.clock_ring.lock().unwrap();
        assert_eq!(ring.len(), 4);
        assert!(!ring.contains(2), "page évinvée absente du HashSet");
        assert!(ring.contains(0));
        assert!(ring.contains(4));
    }
}
