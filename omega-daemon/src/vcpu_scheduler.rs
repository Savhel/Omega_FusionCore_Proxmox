//! Gestionnaire de slots vCPU — modèle élastique avec partage de file d'instructions.
//!
//! # Modèle vCPU
//!
//! ```text
//! Nœud physique
//! ├── pCPU 0  [slot 0, slot 1, slot 2]   ← 3 vCPU max par pCPU
//! ├── pCPU 1  [slot 0, slot 1, slot 2]
//! └── pCPU N  [slot 0, slot 1, slot 2]
//!
//! VM alice  : min=2 vCPU, max=4 vCPU, actuel=2
//! VM bob    : min=1 vCPU, max=2 vCPU, actuel=1
//! VM carol  : min=4 vCPU, max=8 vCPU, actuel=4
//! ```
//!
//! # Élasticité
//!
//! Chaque VM est créée avec un `min_vcpus` (démarrage) et un `max_vcpus`
//! (plafond demandé). Le daemon hotplug des vCPU supplémentaires quand :
//!   - La VM dépasse 80% d'utilisation CPU sur ses vCPU actuels
//!   - Des slots pCPU sont disponibles sur le nœud
//!
//! # Partage de file (instruction sharing)
//!
//! Un slot vCPU peut être partagé entre plusieurs VMs (max `MAX_VMS_PER_SLOT`).
//! En pratique, le scheduler CFS du kernel gère le time-slicing — nous gérons
//! uniquement *quelles VMs* partagent *quel slot* et combien de VMs max.
//!
//! Quand un slot a atteint `MAX_VMS_PER_SLOT` VMs et qu'une nouvelle VM demande
//! un vCPU supplémentaire → décision : **migrer la VM** plutôt que de surcharger.
//!
//! # Steal time
//!
//! Le steal time (temps CPU volé à la VM par l'hyperviseur) est lu depuis
//! `/proc/stat` (champ `steal` de chaque CPU). Un steal > `STEAL_THRESHOLD_PCT`
//! indique un nœud surchargé → déclenche une migration prioritaire.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, RwLock};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;
use tracing::{debug, info, warn};

/// Nombre maximum de vCPUs virtuels par cœur physique.
pub const VCPU_PER_PCPU: usize = 3;

/// Nombre maximum de VMs partageant un même slot vCPU.
pub const MAX_VMS_PER_SLOT: usize = 3;

/// Seuil de steal time déclenchant une migration prioritaire (%).
pub const STEAL_THRESHOLD_PCT: f64 = 10.0;

/// Seuil d'utilisation CPU déclenchant un hotplug de vCPU (%).
pub const HOTPLUG_TRIGGER_PCT: f64 = 80.0;

// ─── Types ────────────────────────────────────────────────────────────────────

/// Identifiant d'un slot vCPU : (pcpu_id, slot_index).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
pub struct SlotId {
    pub pcpu:  usize,
    pub slot:  usize,
}

impl SlotId {
    pub fn new(pcpu: usize, slot: usize) -> Self {
        Self { pcpu, slot }
    }
}

/// État élastique d'une VM.
#[derive(Debug, Clone, Serialize)]
pub struct VmVcpuState {
    pub vm_id:        u32,
    /// vCPUs minimum (démarrage)
    pub min_vcpus:    usize,
    /// vCPUs maximum (plafond demandé par l'utilisateur)
    pub max_vcpus:    usize,
    /// vCPUs actuellement alloués (min ≤ current ≤ max)
    pub current_vcpus: usize,
    /// Slots pCPU assignés à cette VM
    pub slots:        Vec<SlotId>,
    /// Utilisation CPU moyenne sur les 60 dernières secondes (%)
    pub cpu_usage_pct: f64,
    /// Steal time détecté (%)
    pub steal_pct:    f64,
    /// Timestamp de la dernière mise à jour
    pub updated_at:   u64,
}

impl VmVcpuState {
    pub fn new(vm_id: u32, min_vcpus: usize, max_vcpus: usize) -> Self {
        Self {
            vm_id,
            min_vcpus,
            max_vcpus,
            current_vcpus: min_vcpus,
            slots:         Vec::new(),
            cpu_usage_pct: 0.0,
            steal_pct:     0.0,
            updated_at:    now_secs(),
        }
    }

    /// La VM a-t-elle atteint son plafond de vCPUs ?
    pub fn at_max_vcpus(&self) -> bool {
        self.current_vcpus >= self.max_vcpus
    }

    /// La VM est-elle sous pression CPU (dépasse le seuil de hotplug) ?
    pub fn needs_more_vcpus(&self) -> bool {
        self.cpu_usage_pct >= HOTPLUG_TRIGGER_PCT && !self.at_max_vcpus()
    }

    /// La VM souffre-t-elle de steal time excessif ?
    pub fn has_steal_pressure(&self) -> bool {
        self.steal_pct >= STEAL_THRESHOLD_PCT
    }
}

// ─── Registre des slots ───────────────────────────────────────────────────────

/// Un slot vCPU et les VMs qui le partagent.
#[derive(Debug, Default)]
struct PcpuSlot {
    /// VMs assignées à ce slot (max MAX_VMS_PER_SLOT)
    vms: HashSet<u32>,
}

impl PcpuSlot {
    fn can_accept(&self) -> bool {
        self.vms.len() < MAX_VMS_PER_SLOT
    }

}

// ─── VcpuScheduler ───────────────────────────────────────────────────────────

/// Résultat d'une décision d'allocation vCPU.
#[derive(Debug, Clone)]
pub enum VcpuDecision {
    /// Slots alloués avec succès.
    Allocated { vm_id: u32, slots: Vec<SlotId> },
    /// Un vCPU supplémentaire a été hotplugué.
    Hotplugged { vm_id: u32, new_count: usize, slot: SlotId },
    /// Plus de slots disponibles → migration recommandée.
    MigrateRequired {
        vm_id:  u32,
        reason: String,
    },
    /// La VM est déjà à son maximum.
    AtMax { vm_id: u32 },
}

/// Scheduler de vCPU — gère les slots pCPU et l'élasticité des VMs.
pub struct VcpuScheduler {
    /// Nombre de CPUs physiques du nœud
    num_pcpus: usize,
    /// Slots : [pcpu_id][slot_index]
    slots:     RwLock<Vec<Vec<PcpuSlot>>>,
    /// États des VMs
    vms:       RwLock<HashMap<u32, VmVcpuState>>,
}

impl VcpuScheduler {
    /// Crée un scheduler pour un nœud avec `num_pcpus` cœurs physiques.
    pub fn new(num_pcpus: usize) -> Arc<Self> {
        let slots = (0..num_pcpus)
            .map(|_| (0..VCPU_PER_PCPU).map(|_| PcpuSlot::default()).collect())
            .collect();

        info!(
            num_pcpus,
            total_vslots = num_pcpus * VCPU_PER_PCPU,
            max_vms_per_slot = MAX_VMS_PER_SLOT,
            "VcpuScheduler initialisé"
        );

        Arc::new(Self {
            num_pcpus,
            slots: RwLock::new(slots),
            vms:   RwLock::new(HashMap::new()),
        })
    }

    // ─── Admission ────────────────────────────────────────────────────────

    /// Enregistre une nouvelle VM et lui alloue ses `min_vcpus` slots.
    ///
    /// Retourne `VcpuDecision::MigrateRequired` si le nœud n'a plus de place.
    pub fn admit_vm(
        &self,
        vm_id:     u32,
        min_vcpus: usize,
        max_vcpus: usize,
    ) -> VcpuDecision {
        let mut vms   = self.vms.write().unwrap();
        let mut slots = self.slots.write().unwrap();

        // Trouver min_vcpus slots libres
        let mut allocated: Vec<SlotId> = Vec::new();

        'outer: for pcpu in 0..self.num_pcpus {
            for slot in 0..VCPU_PER_PCPU {
                if allocated.len() >= min_vcpus { break 'outer; }
                if slots[pcpu][slot].can_accept() {
                    slots[pcpu][slot].vms.insert(vm_id);
                    allocated.push(SlotId::new(pcpu, slot));
                }
            }
        }

        if allocated.len() < min_vcpus {
            // Libérer ce qu'on a partiellement alloué
            for sid in &allocated {
                slots[sid.pcpu][sid.slot].vms.remove(&vm_id);
            }
            return VcpuDecision::MigrateRequired {
                vm_id,
                reason: format!(
                    "nœud saturé : seulement {} slots disponibles sur {} demandés",
                    allocated.len(), min_vcpus
                ),
            };
        }

        let mut state = VmVcpuState::new(vm_id, min_vcpus, max_vcpus);
        state.slots = allocated.clone();

        info!(
            vm_id,
            min_vcpus,
            max_vcpus,
            slots_allocated = allocated.len(),
            "VM admise dans le scheduler vCPU"
        );

        vms.insert(vm_id, state);
        VcpuDecision::Allocated { vm_id, slots: allocated }
    }

    /// Libère tous les slots d'une VM (arrêt ou migration).
    pub fn release_vm(&self, vm_id: u32) {
        let mut vms   = self.vms.write().unwrap();
        let mut slots = self.slots.write().unwrap();

        if let Some(state) = vms.remove(&vm_id) {
            for sid in &state.slots {
                slots[sid.pcpu][sid.slot].vms.remove(&vm_id);
            }
            info!(vm_id, released_slots = state.slots.len(), "VM retirée du scheduler");
        }
    }

    // ─── Élasticité ───────────────────────────────────────────────────────

    /// Tente de hotpluguer un vCPU supplémentaire pour une VM.
    ///
    /// Appelé quand `cpu_usage_pct ≥ HOTPLUG_TRIGGER_PCT`.
    pub fn try_hotplug(&self, vm_id: u32) -> VcpuDecision {
        let mut vms   = self.vms.write().unwrap();
        let mut slots = self.slots.write().unwrap();

        let Some(state) = vms.get_mut(&vm_id) else {
            return VcpuDecision::MigrateRequired {
                vm_id,
                reason: "VM inconnue".into(),
            };
        };

        if state.at_max_vcpus() {
            debug!(vm_id, max = state.max_vcpus, "VM déjà à son max vCPU");
            return VcpuDecision::AtMax { vm_id };
        }

        // Chercher un slot libre (préférence : même pCPU pour localité)
        let preferred_pcpus: Vec<usize> = state.slots.iter().map(|s| s.pcpu).collect();
        let all_pcpus: Vec<usize>       = (0..self.num_pcpus).collect();

        let search_order: Vec<usize> = preferred_pcpus.into_iter()
            .chain(all_pcpus)
            .collect::<Vec<_>>()
            .into_iter()
            .collect::<HashSet<_>>()
            .into_iter()
            .collect();

        for pcpu in search_order {
            for slot in 0..VCPU_PER_PCPU {
                if slots[pcpu][slot].can_accept() {
                    slots[pcpu][slot].vms.insert(vm_id);
                    let sid        = SlotId::new(pcpu, slot);
                    state.slots.push(sid);
                    let new_count  = state.current_vcpus + 1;
                    state.current_vcpus = new_count;
                    state.updated_at    = now_secs();

                    info!(
                        vm_id,
                        new_count,
                        pcpu,
                        slot,
                        "vCPU hotplugué"
                    );
                    return VcpuDecision::Hotplugged { vm_id, new_count, slot: sid };
                }
            }
        }

        // Plus de slots disponibles
        warn!(
            vm_id,
            current = state.current_vcpus,
            max     = state.max_vcpus,
            "hotplug impossible — nœud saturé → migration recommandée"
        );

        VcpuDecision::MigrateRequired {
            vm_id,
            reason: format!(
                "plus de slots vCPU disponibles ({}/{} vCPU alloués, max demandé {})",
                state.current_vcpus,
                self.total_vslots(),
                state.max_vcpus,
            ),
        }
    }

    // ─── Monitoring ───────────────────────────────────────────────────────

    /// Met à jour les métriques CPU d'une VM (usage, steal).
    pub fn update_vm_metrics(&self, vm_id: u32, cpu_usage_pct: f64, steal_pct: f64) {
        let mut vms = self.vms.write().unwrap();
        if let Some(state) = vms.get_mut(&vm_id) {
            state.cpu_usage_pct = cpu_usage_pct;
            state.steal_pct     = steal_pct;
            state.updated_at    = now_secs();

            if state.has_steal_pressure() {
                warn!(
                    vm_id,
                    steal_pct,
                    "steal time élevé — nœud surchargé, migration prioritaire recommandée"
                );
            }
        }
    }

    /// Lit le steal time global du nœud depuis /proc/stat.
    ///
    /// Sur machine physique : mesure l'overhead des autres processus hôte.
    /// Sur VM Proxmox (lab KVM) : mesure le temps volé par l'hyperviseur.
    ///
    /// Pour des métriques par VM (précises), utiliser `CgroupCpuController::read_cpu_stat`.
    pub fn read_node_steal_pct(&self) -> f64 {
        read_steal_from_proc_stat().unwrap_or(0.0)
    }

    /// Met à jour les métriques d'une VM depuis son cgroup v2.
    ///
    /// Plus précis que update_vm_metrics() car les données viennent
    /// directement du kernel (pas d'interpolation).
    pub fn update_from_cgroup(
        &self,
        vm_id: u32,
        usage_pct: f64,
        throttle_ratio: f64,
    ) {
        // Le steal time par VM n'existe pas sur physique (c'est un concept
        // hyperviseur). On utilise le throttle_ratio comme proxy : une VM
        // throttlée est une VM qui a besoin de plus de CPU qu'on ne lui donne.
        let effective_steal = throttle_ratio * 100.0;
        self.update_vm_metrics(vm_id, usage_pct, effective_steal);
    }

    /// VMs qui ont besoin d'un hotplug (usage > seuil, pas au max).
    pub fn vms_needing_hotplug(&self) -> Vec<u32> {
        self.vms.read().unwrap()
            .values()
            .filter(|s| s.needs_more_vcpus())
            .map(|s| s.vm_id)
            .collect()
    }

    /// VMs candidates à la migration (steal élevé ou nœud saturé).
    pub fn vms_needing_migration(&self) -> Vec<(u32, String)> {
        self.vms.read().unwrap()
            .values()
            .filter(|s| s.has_steal_pressure())
            .map(|s| (s.vm_id, format!("steal {:.1}%", s.steal_pct)))
            .collect()
    }

    // ─── Snapshot / métriques ─────────────────────────────────────────────

    /// Nombre de slots vCPU totaux sur le nœud.
    pub fn total_vslots(&self) -> usize {
        self.num_pcpus * VCPU_PER_PCPU
    }

    /// Nombre de slots vCPU encore disponibles.
    pub fn free_vslots(&self) -> usize {
        let slots = self.slots.read().unwrap();
        slots.iter().flatten()
            .filter(|s| s.can_accept())
            .count()
    }

    /// Taux d'occupation global (0.0 – 1.0).
    pub fn occupancy_ratio(&self) -> f64 {
        let total  = self.total_vslots();
        let free   = self.free_vslots();
        if total == 0 { return 0.0; }
        1.0 - (free as f64 / total as f64)
    }

    /// Snapshot de l'état de toutes les VMs.
    pub fn vm_snapshot(&self) -> Vec<VmVcpuState> {
        self.vms.read().unwrap().values().cloned().collect()
    }

    /// Résumé pour les métriques Prometheus.
    pub fn prometheus_metrics(&self, node_id: &str) -> String {
        let total    = self.total_vslots();
        let free     = self.free_vslots();
        let used     = total - free;
        let steal    = self.read_node_steal_pct();
        let vms      = self.vms.read().unwrap();
        let vm_count = vms.len();

        format!(
            "# HELP omega_vcpu_slots_total Slots vCPU totaux\n\
             omega_vcpu_slots_total{{node=\"{node}\"}} {total}\n\
             # HELP omega_vcpu_slots_used Slots vCPU utilisés\n\
             omega_vcpu_slots_used{{node=\"{node}\"}} {used}\n\
             # HELP omega_vcpu_slots_free Slots vCPU libres\n\
             omega_vcpu_slots_free{{node=\"{node}\"}} {free}\n\
             # HELP omega_vcpu_steal_pct Steal time CPU nœud (%)\n\
             omega_vcpu_steal_pct{{node=\"{node}\"}} {steal:.2}\n\
             # HELP omega_vcpu_vm_count VMs gérées par le scheduler\n\
             omega_vcpu_vm_count{{node=\"{node}\"}} {vm_count}\n",
            node  = node_id,
        )
    }
}

// ─── Lecture /proc/stat ───────────────────────────────────────────────────────

fn read_steal_from_proc_stat() -> Option<f64> {
    let content = std::fs::read_to_string("/proc/stat").ok()?;
    let line    = content.lines().find(|l| l.starts_with("cpu "))?;

    // Format: cpu user nice system idle iowait irq softirq steal guest guest_nice
    let fields: Vec<u64> = line.split_whitespace()
        .skip(1)
        .filter_map(|s| s.parse().ok())
        .collect();

    if fields.len() < 8 { return None; }

    let total = fields.iter().sum::<u64>();
    let steal = fields[7];  // champ steal

    if total == 0 { return Some(0.0); }
    Some((steal as f64 / total as f64) * 100.0)
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn make_scheduler(pcpus: usize) -> Arc<VcpuScheduler> {
        VcpuScheduler::new(pcpus)
    }

    #[test]
    fn test_total_slots_is_pcpus_times_3() {
        let s = make_scheduler(4);
        assert_eq!(s.total_vslots(), 12);
    }

    #[test]
    fn test_admit_vm_allocates_min_vcpus() {
        // Un slot accepte jusqu'à MAX_VMS_PER_SLOT (3) VMs.
        // free_vslots() = nombre de slots pouvant encore accueillir une VM.
        // Pour qu'un slot soit saturé il faut y placer 3 VMs (min=1 chacune).
        let s = make_scheduler(4);  // 12 slots
        s.admit_vm(1, 1, 2);
        s.admit_vm(2, 1, 2);
        s.admit_vm(3, 1, 2);  // slot[0][0] plein (3 VMs = MAX_VMS_PER_SLOT)
        let d = s.admit_vm(4, 1, 2);
        assert!(matches!(d, VcpuDecision::Allocated { .. }));
        // 1 slot saturé sur 12 → 11 libres
        assert_eq!(s.free_vslots(), 12 - 1);
    }

    #[test]
    fn test_admit_multiple_vms_same_slots() {
        // 3 VMs sur 1 pCPU, 1 slot : toutes partagent le même slot
        let s = make_scheduler(1);  // 1 pCPU = 3 slots
        s.admit_vm(1, 1, 2);
        s.admit_vm(2, 1, 2);
        s.admit_vm(3, 1, 2);
        // 4ème VM sur le même slot → dépassement MAX_VMS_PER_SLOT
        // mais il reste 2 autres slots sur le même pCPU
        let d = s.admit_vm(4, 1, 2);
        assert!(matches!(d, VcpuDecision::Allocated { .. }));
    }

    #[test]
    fn test_migrate_required_when_no_slots() {
        let s = make_scheduler(1);  // 3 slots, 3 VMs chacune prend les 3 max
        // Remplir tous les slots : 3 slots × 3 VMs max = 9 admissions
        for i in 1u32..=9 {
            let _ = s.admit_vm(i, 1, 2);
        }
        // La 10ème doit être refusée
        let d = s.admit_vm(10, 1, 2);
        assert!(matches!(d, VcpuDecision::MigrateRequired { .. }));
    }

    #[test]
    fn test_release_frees_slots() {
        // Remplir complètement 1 slot : 3 VMs dans slot[0][0] → 5 slots libres sur 6.
        let s = make_scheduler(2);  // 6 slots
        s.admit_vm(1, 1, 2);
        s.admit_vm(2, 1, 2);
        s.admit_vm(3, 1, 2);  // slot[0][0] saturé
        assert_eq!(s.free_vslots(), 5);  // 1 saturé → 5 libres

        s.release_vm(1);
        s.release_vm(2);
        s.release_vm(3);
        assert_eq!(s.free_vslots(), 6);  // tout libéré
    }

    #[test]
    fn test_hotplug_increases_vcpu_count() {
        let s = make_scheduler(4);
        s.admit_vm(1, 2, 4);
        s.update_vm_metrics(1, 85.0, 0.0);  // > HOTPLUG_TRIGGER_PCT

        let vms_to_hotplug = s.vms_needing_hotplug();
        assert!(vms_to_hotplug.contains(&1));

        let d = s.try_hotplug(1);
        assert!(matches!(d, VcpuDecision::Hotplugged { new_count: 3, .. }));
    }

    #[test]
    fn test_hotplug_stops_at_max_vcpus() {
        let s = make_scheduler(4);
        s.admit_vm(1, 2, 2);  // min=max=2 → pas d'élasticité

        let d = s.try_hotplug(1);
        assert!(matches!(d, VcpuDecision::AtMax { .. }));
    }

    #[test]
    fn test_steal_pressure_detected() {
        let s = make_scheduler(2);
        s.admit_vm(1, 2, 4);
        s.update_vm_metrics(1, 50.0, 15.0);  // steal 15% > STEAL_THRESHOLD_PCT

        let candidates = s.vms_needing_migration();
        assert!(candidates.iter().any(|(id, _)| *id == 1));
    }

    #[test]
    fn test_occupancy_ratio_zero_when_empty() {
        let s = make_scheduler(4);
        assert_eq!(s.occupancy_ratio(), 0.0);
    }

    #[test]
    fn test_occupancy_ratio_increases_with_vms() {
        // occupancy_ratio = slots_saturés / total_slots.
        // Pour 50% avec 12 slots : saturer 6 slots = 6 × 3 VMs = 18 VMs (min=1).
        let s = make_scheduler(4);  // 12 slots
        for i in 1u32..=18 {
            s.admit_vm(i, 1, 2);  // les 18 premières VMs remplissent 6 slots
        }
        let ratio = s.occupancy_ratio();
        assert!((ratio - 0.5).abs() < 0.01);
    }
}
