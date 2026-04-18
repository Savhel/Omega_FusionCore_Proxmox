"""
Contrôleur d'admission vCPU — gestion élastique des cœurs virtuels.

Modèle :
  - 1 pCPU physique = 3 vCPU
  - 1 slot vCPU peut être partagé entre MAX_VMS_PER_SLOT=3 VMs maximum
    (les instructions en attente sont chargées dans la file d'un autre vCPU libre)
  - Chaque VM déclare un min_vcpus et un max_vcpus à la création
  - Elle démarre avec min_vcpus, obtient des hotplugs jusqu'à max_vcpus selon la demande
  - Si le nœud n'a plus de vCPU disponibles ET qu'une VM a besoin de plus que son quota
    actuel → migration vers un nœud moins chargé

Invariants garantis :
  - allocated_vcpus(vm) ∈ [min_vcpus, max_vcpus]
  - sum(allocated_vcpus) ≤ num_pcpus * VCPU_PER_PCPU * MAX_VMS_PER_SLOT
  - Un vCPU partagé entre > MAX_VMS_PER_SLOT VMs → refus d'admission / migration
"""

from __future__ import annotations

import threading
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

# ── Constantes du modèle ─────────────────────────────────────────────────────

VCPU_PER_PCPU: int     = 3   # vCPU physiques par cœur
MAX_VMS_PER_SLOT: int  = 3   # VMs max pouvant partager un vCPU slot
STEAL_THRESHOLD_PCT: float = 10.0  # steal% au-delà duquel on envisage la migration


# ── Structures de données ─────────────────────────────────────────────────────

@dataclass
class VmCpuSpec:
    """Spécification CPU d'une VM à sa création."""
    vmid:       int
    min_vcpus:  int   # minimum garanti (VM démarre avec ça)
    max_vcpus:  int   # plafond absolu demandé par la VM

    def __post_init__(self) -> None:
        if self.min_vcpus < 1:
            raise ValueError(f"min_vcpus doit être ≥ 1, reçu {self.min_vcpus}")
        if self.max_vcpus < self.min_vcpus:
            raise ValueError(
                f"max_vcpus ({self.max_vcpus}) < min_vcpus ({self.min_vcpus})"
            )


@dataclass
class VmCpuState:
    """État courant des vCPU d'une VM sur un nœud."""
    vmid:              int
    min_vcpus:         int
    max_vcpus:         int
    allocated_vcpus:   int          # actuellement allouées
    cpu_usage_pct:     float = 0.0  # % CPU moyen sur la fenêtre
    steal_pct:         float = 0.0  # steal time % récent
    node_id:           str  = ""

    def needs_more_vcpus(self) -> bool:
        """Vrai si la VM est sous pression CPU et peut encore recevoir des vCPUs."""
        return (
            self.cpu_usage_pct >= 80.0
            and self.allocated_vcpus < self.max_vcpus
        )

    def needs_migration(self) -> bool:
        """
        Vrai si la VM est à son max et souffre de steal — elle a besoin d'un nœud
        plus libre, pas d'un hotplug supplémentaire.
        """
        return (
            self.steal_pct >= STEAL_THRESHOLD_PCT
            and self.allocated_vcpus >= self.max_vcpus
        )


@dataclass
class NodeCpuCapacity:
    """Capacité CPU d'un nœud telle que déclarée / observée."""
    node_id:       str
    num_pcpus:     int
    steal_pct:     float = 0.0   # steal % courant lu sur /proc/stat
    cpu_usage_pct: float = 0.0   # utilisation globale

    @property
    def total_vcpu_slots(self) -> int:
        """Nombre total de slots vCPU disponibles (3 vCPU × pCPU × 3 VMs)."""
        return self.num_pcpus * VCPU_PER_PCPU * MAX_VMS_PER_SLOT

    def is_overloaded(self) -> bool:
        return self.steal_pct >= STEAL_THRESHOLD_PCT or self.cpu_usage_pct >= 90.0


@dataclass
class CpuAdmissionDecision:
    """Résultat d'une décision d'admission CPU."""
    admitted:        bool
    vmid:            int
    node_id:         str
    allocated_vcpus: int   # vCPUs accordées au démarrage (= min_vcpus si admitted)
    max_vcpus:       int   # plafond conservé
    reason:          str   = ""

    def admission_payload(self) -> dict:
        """Corps prêt pour POST /control/vm/{vmid}/vcpu."""
        return {
            "vmid":            self.vmid,
            "allocated_vcpus": self.allocated_vcpus,
            "max_vcpus":       self.max_vcpus,
        }


# ── Registre local (par nœud) ─────────────────────────────────────────────────

class NodeVcpuRegistry:
    """
    Registre des vCPU allouées sur un nœud unique.
    Thread-safe, utilisé par le daemon Rust via le control_api ou par le controller.
    """

    def __init__(self, node_id: str, num_pcpus: int) -> None:
        self._node_id   = node_id
        self._num_pcpus = num_pcpus
        self._lock      = threading.RLock()
        self._vms: Dict[int, VmCpuState] = {}  # vmid → state

    # ── Capacité ─────────────────────────────────────────────────────────────

    @property
    def total_vcpu_slots(self) -> int:
        return self._num_pcpus * VCPU_PER_PCPU * MAX_VMS_PER_SLOT

    def allocated_vcpus(self) -> int:
        with self._lock:
            return sum(v.allocated_vcpus for v in self._vms.values())

    def free_vcpu_slots(self) -> int:
        return max(0, self.total_vcpu_slots - self.allocated_vcpus())

    # ── Admission ────────────────────────────────────────────────────────────

    def admit(self, spec: VmCpuSpec) -> CpuAdmissionDecision:
        """
        Tente d'admettre une VM sur ce nœud avec spec.min_vcpus vCPUs.
        Échoue si plus assez de slots disponibles.
        """
        with self._lock:
            if spec.vmid in self._vms:
                return CpuAdmissionDecision(
                    admitted=False,
                    vmid=spec.vmid,
                    node_id=self._node_id,
                    allocated_vcpus=0,
                    max_vcpus=spec.max_vcpus,
                    reason=f"VM {spec.vmid} déjà enregistrée sur ce nœud",
                )

            free = self.free_vcpu_slots()
            if free < spec.min_vcpus:
                return CpuAdmissionDecision(
                    admitted=False,
                    vmid=spec.vmid,
                    node_id=self._node_id,
                    allocated_vcpus=0,
                    max_vcpus=spec.max_vcpus,
                    reason=(
                        f"slots libres insuffisants : {free} < {spec.min_vcpus} requis"
                    ),
                )

            state = VmCpuState(
                vmid=spec.vmid,
                min_vcpus=spec.min_vcpus,
                max_vcpus=spec.max_vcpus,
                allocated_vcpus=spec.min_vcpus,
                node_id=self._node_id,
            )
            self._vms[spec.vmid] = state

            return CpuAdmissionDecision(
                admitted=True,
                vmid=spec.vmid,
                node_id=self._node_id,
                allocated_vcpus=spec.min_vcpus,
                max_vcpus=spec.max_vcpus,
                reason="admis",
            )

    def release(self, vmid: int) -> None:
        with self._lock:
            self._vms.pop(vmid, None)

    # ── Hotplug ──────────────────────────────────────────────────────────────

    def try_hotplug(self, vmid: int, delta: int = 1) -> Tuple[bool, str]:
        """
        Tente d'allouer `delta` vCPUs supplémentaires à la VM.
        Retourne (succès, raison).
        """
        with self._lock:
            vm = self._vms.get(vmid)
            if vm is None:
                return False, f"VM {vmid} inconnue"
            if vm.allocated_vcpus + delta > vm.max_vcpus:
                return False, (
                    f"plafond atteint : {vm.allocated_vcpus}+{delta} > {vm.max_vcpus}"
                )
            free = self.free_vcpu_slots()
            if free < delta:
                return False, f"slots libres insuffisants : {free} < {delta}"

            vm.allocated_vcpus += delta
            return True, f"hotplug +{delta} → {vm.allocated_vcpus} vCPUs"

    # ── Métriques ────────────────────────────────────────────────────────────

    def update_metrics(self, vmid: int, cpu_usage_pct: float, steal_pct: float) -> None:
        with self._lock:
            vm = self._vms.get(vmid)
            if vm:
                vm.cpu_usage_pct = cpu_usage_pct
                vm.steal_pct     = steal_pct

    def vms_needing_hotplug(self) -> List[int]:
        with self._lock:
            return [v.vmid for v in self._vms.values() if v.needs_more_vcpus()]

    def vms_needing_migration(self) -> List[int]:
        with self._lock:
            return [v.vmid for v in self._vms.values() if v.needs_migration()]

    def snapshot(self) -> List[VmCpuState]:
        with self._lock:
            return list(self._vms.values())

    def get_vm(self, vmid: int) -> Optional[VmCpuState]:
        with self._lock:
            return self._vms.get(vmid)


# ── Contrôleur d'admission cluster ───────────────────────────────────────────

class CpuAdmissionController:
    """
    Admission CPU au niveau cluster — choisit le nœud cible et applique
    le modèle élastique min/max.

    Le controller Python l'utilise pour décider où placer une VM et avec
    combien de vCPUs elle démarre.
    """

    def __init__(self, nodes: Dict[str, NodeCpuCapacity]) -> None:
        """
        nodes : { node_id → NodeCpuCapacity }
        """
        self._nodes:     Dict[str, NodeCpuCapacity]     = nodes
        self._registries: Dict[str, NodeVcpuRegistry]   = {
            nid: NodeVcpuRegistry(nid, cap.num_pcpus)
            for nid, cap in nodes.items()
        }
        self._lock = threading.Lock()

    # ── Sélection du nœud ────────────────────────────────────────────────────

    def _best_node_for(self, spec: VmCpuSpec) -> Optional[str]:
        """
        Choisit le nœud avec le plus de slots libres ET non surchargé.
        Retourne None si aucun nœud ne peut accueillir spec.min_vcpus.
        """
        candidates = []
        for nid, reg in self._registries.items():
            cap   = self._nodes[nid]
            free  = reg.free_vcpu_slots()
            if free >= spec.min_vcpus and not cap.is_overloaded():
                candidates.append((nid, free))

        if not candidates:
            return None

        # Le nœud avec le plus de slots libres en premier
        candidates.sort(key=lambda x: -x[1])
        return candidates[0][0]

    # ── Admission ────────────────────────────────────────────────────────────

    def admit(
        self,
        spec: VmCpuSpec,
        preferred_node: Optional[str] = None,
    ) -> CpuAdmissionDecision:
        """
        Admet une VM dans le cluster.  Retourne une décision avec node_id et
        le nombre de vCPUs allouées au démarrage (= min_vcpus).
        """
        with self._lock:
            # 1. Essayer le nœud préféré d'abord
            if preferred_node and preferred_node in self._registries:
                cap = self._nodes[preferred_node]
                reg = self._registries[preferred_node]
                if reg.free_vcpu_slots() >= spec.min_vcpus and not cap.is_overloaded():
                    return reg.admit(spec)

            # 2. Meilleur nœud disponible
            target = self._best_node_for(spec)
            if target is None:
                return CpuAdmissionDecision(
                    admitted=False,
                    vmid=spec.vmid,
                    node_id="",
                    allocated_vcpus=0,
                    max_vcpus=spec.max_vcpus,
                    reason="aucun nœud disponible avec assez de slots vCPU libres",
                )

            return self._registries[target].admit(spec)

    def release(self, vmid: int, node_id: str) -> None:
        reg = self._registries.get(node_id)
        if reg:
            reg.release(vmid)

    # ── Hotplug cluster ───────────────────────────────────────────────────────

    def try_hotplug(self, vmid: int, node_id: str, delta: int = 1) -> Tuple[bool, str]:
        reg = self._registries.get(node_id)
        if reg is None:
            return False, f"nœud {node_id} inconnu"
        return reg.try_hotplug(vmid, delta)

    # ── Métriques ────────────────────────────────────────────────────────────

    def update_node_capacity(self, node_id: str, cap: NodeCpuCapacity) -> None:
        with self._lock:
            self._nodes[node_id] = cap

    def update_vm_metrics(
        self,
        vmid: int,
        node_id: str,
        cpu_usage_pct: float,
        steal_pct: float,
    ) -> None:
        reg = self._registries.get(node_id)
        if reg:
            reg.update_metrics(vmid, cpu_usage_pct, steal_pct)

    def cluster_snapshot(self) -> Dict[str, List[VmCpuState]]:
        return {nid: reg.snapshot() for nid, reg in self._registries.items()}

    def hotplug_candidates(self) -> Dict[str, List[int]]:
        """VMs par nœud ayant besoin d'un hotplug vCPU."""
        return {
            nid: reg.vms_needing_hotplug()
            for nid, reg in self._registries.items()
        }

    def migration_candidates(self) -> Dict[str, List[int]]:
        """VMs par nœud devant être migrées (steal trop élevé, au max de vCPU)."""
        return {
            nid: reg.vms_needing_migration()
            for nid, reg in self._registries.items()
        }

    def free_slots_per_node(self) -> Dict[str, int]:
        return {nid: reg.free_vcpu_slots() for nid, reg in self._registries.items()}
