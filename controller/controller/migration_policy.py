"""
Politique de migration de VMs — décide quand migrer, vers où, et comment.

# Rôle dans l'architecture

Le controller Python a une vue globale du cluster (il parle à tous les nœuds).
C'est lui qui :
  1. Collecte l'état de chaque nœud via GET /control/status
  2. Décide quel nœud est surchargé et lequel peut accueillir une VM
  3. Choisit le type de migration (live ou cold)
  4. Appelle POST /control/migrate sur le nœud source

Le daemon Rust reçoit l'ordre et exécute `qm migrate`.

# Règles de décision live vs cold

  ┌──────────────────────┬─────────────────────┬───────────────────┐
  │ État VM              │ Pression nœud       │ Type              │
  ├──────────────────────┼─────────────────────┼───────────────────┤
  │ Stopped              │ peu importe         │ COLD              │
  │ Running, CPU > 5%    │ RAM > 85%           │ LIVE              │
  │ Running, CPU < 5%    │ RAM > 85% (> 60s)  │ COLD              │
  │ Running, CPU > 5%    │ RAM > 95% (critique)│ COLD (urgence)    │
  │ Running, throttlé    │ vCPU saturé         │ LIVE              │
  └──────────────────────┴─────────────────────┴───────────────────┘

# Choix de la cible

  La cible est le nœud avec le meilleur score composite :
    score = (1 - ram_usage) × 0.6 + (1 - vcpu_usage) × 0.4
  On n'envoie jamais vers un nœud avec RAM > 80% ou vCPU > 80%.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Dict, List, Optional, Tuple


# ─── Types ────────────────────────────────────────────────────────────────────

class MigrationType(str, Enum):
    LIVE = "live"   # VM reste allumée, KVM pre-copy
    COLD = "cold"   # VM stoppée, transférée, redémarrée


class MigrationReason(str, Enum):
    MEMORY_PRESSURE      = "memory_pressure"
    CPU_SATURATION       = "cpu_saturation"
    EXCESSIVE_REMOTE_PAGING = "excessive_remote_paging"
    MAINTENANCE_DRAIN    = "maintenance_drain"
    ADMIN_REQUEST        = "admin_request"


@dataclass
class NodeState:
    """Snapshot de l'état d'un nœud tel que retourné par GET /control/status."""
    node_id:          str
    mem_total_kb:     int
    mem_available_kb: int
    vcpu_total:       int       = 24
    vcpu_free:        int       = 24
    local_vms:        List[VmState] = field(default_factory=list)

    @property
    def ram_used_pct(self) -> float:
        if self.mem_total_kb == 0:
            return 0.0
        return (self.mem_total_kb - self.mem_available_kb) / self.mem_total_kb * 100.0

    @property
    def vcpu_used_pct(self) -> float:
        if self.vcpu_total == 0:
            return 0.0
        return (self.vcpu_total - self.vcpu_free) / self.vcpu_total * 100.0

    def placement_score(self) -> float:
        """Score de capacité d'accueil : plus haut = meilleur nœud cible."""
        ram_free_ratio  = 1.0 - self.ram_used_pct  / 100.0
        vcpu_free_ratio = 1.0 - self.vcpu_used_pct / 100.0
        return ram_free_ratio * 0.6 + vcpu_free_ratio * 0.4

    def can_accept_vm(self, vm: "VmState") -> bool:
        """Vérifie si ce nœud peut accueillir la VM sans dépasser 80%."""
        vm_ram_kb = vm.max_mem_mib * 1024
        new_avail = self.mem_available_kb - vm_ram_kb
        new_avail_pct = new_avail / self.mem_total_kb * 100.0 if self.mem_total_kb else 0.0
        ram_ok  = new_avail_pct >= 20.0  # garder 20% libres
        vcpu_ok = self.vcpu_used_pct < 80.0
        return ram_ok and vcpu_ok


@dataclass
class VmState:
    """État d'une VM locale sur un nœud."""
    vm_id:          int
    status:         str          # "running" | "stopped" | "unknown"
    max_mem_mib:    int
    rss_kb:         int          = 0
    remote_pages:   int          = 0
    avg_cpu_pct:    float        = 0.0
    throttle_ratio: float        = 0.0
    idle_since:     Optional[float] = None   # timestamp monotonic depuis quand idle

    @property
    def is_running(self) -> bool:
        return self.status == "running"

    @property
    def is_stopped(self) -> bool:
        return self.status == "stopped"

    @property
    def remote_pct(self) -> float:
        total_pages = self.max_mem_mib * 256  # pages 4Ko dans max_mem_mib
        if total_pages == 0:
            return 0.0
        return self.remote_pages / total_pages * 100.0

    def idle_duration_secs(self) -> float:
        if self.idle_since is None:
            return 0.0
        return time.monotonic() - self.idle_since


@dataclass
class MigrationCandidate:
    """Résultat d'évaluation : une VM à migrer avec sa cible et son type."""
    vm:        VmState
    source:    str
    target:    str
    mtype:     MigrationType
    reason:    MigrationReason
    urgency:   int          = 0   # 0 = faible, 1 = normale, 2 = urgente
    detail:    str          = ""

    def to_api_payload(self) -> dict:
        return {
            "vm_id":  self.vm.vm_id,
            "source": self.source,
            "target": self.target,
            "type":   self.mtype.value,
            "reason": self.reason.value,
            "detail": self.detail,
        }


# ─── Seuils ───────────────────────────────────────────────────────────────────

@dataclass
class MigrationThresholds:
    # RAM
    ram_high_pct:      float = 85.0   # pression haute → live migration
    ram_critical_pct:  float = 95.0   # pression critique → cold forcée

    # vCPU
    vcpu_throttle_trigger: float = 0.30   # throttle > 30% → migrer
    vcpu_saturation_pct:   float = 90.0   # nœud > 90% utilisé → migrer

    # Remote paging
    remote_paging_pct: float = 60.0   # > 60% de la RAM en distant → migrer

    # Idle detection
    idle_cpu_pct:        float = 5.0    # < 5% CPU → VM idle
    idle_duration_secs:  float = 60.0   # idle depuis > 60s → cold acceptable

    # Cible
    target_max_ram_pct:  float = 80.0   # nœud cible doit avoir < 80% RAM utilisée
    target_max_vcpu_pct: float = 80.0   # nœud cible doit avoir < 80% vCPU utilisés


# ─── Politique principale ─────────────────────────────────────────────────────

class MigrationPolicy:
    """
    Évalue l'état du cluster et retourne des recommandations de migration.

    Utilisation typique :
        policy = MigrationPolicy(thresholds)
        candidates = policy.evaluate(node_states)
        for c in candidates[:2]:              # exécuter max 2 migrations simultanées
            daemon_api.post(c.source, "/control/migrate", c.to_api_payload())
    """

    def __init__(self, thresholds: MigrationThresholds = MigrationThresholds()) -> None:
        self.thresholds = thresholds

    def evaluate(
        self,
        node_states: Dict[str, NodeState],
    ) -> List[MigrationCandidate]:
        """
        Analyse tous les nœuds et retourne les migrations recommandées,
        triées par urgence décroissante.
        """
        candidates: List[MigrationCandidate] = []
        t = self.thresholds

        for node_id, node in node_states.items():
            for vm in node.local_vms:

                # ── 1. Remote paging excessif ──────────────────────────────
                if vm.remote_pct > t.remote_paging_pct:
                    target = self._best_target(node_id, vm, node_states)
                    if target:
                        mtype = self._pick_type(vm, critical=False)
                        candidates.append(MigrationCandidate(
                            vm=vm, source=node_id, target=target,
                            mtype=mtype,
                            reason=MigrationReason.EXCESSIVE_REMOTE_PAGING,
                            urgency=1,
                            detail=f"{vm.remote_pct:.0f}% RAM stockée à distance",
                        ))

                # ── 2. Pression RAM critique (≥ 95%) ───────────────────────
                if node.ram_used_pct >= t.ram_critical_pct:
                    target = self._best_target(node_id, vm, node_states)
                    if target:
                        candidates.append(MigrationCandidate(
                            vm=vm, source=node_id, target=target,
                            mtype=MigrationType.COLD,  # urgence = cold forcée
                            reason=MigrationReason.MEMORY_PRESSURE,
                            urgency=2,
                            detail=f"RAM nœud {node.ram_used_pct:.0f}% (critique ≥ {t.ram_critical_pct:.0f}%)",
                        ))

                # ── 3. Pression RAM haute (≥ 85%) ──────────────────────────
                elif node.ram_used_pct >= t.ram_high_pct:
                    target = self._best_target(node_id, vm, node_states)
                    if target:
                        mtype = self._pick_type(vm, critical=False)
                        candidates.append(MigrationCandidate(
                            vm=vm, source=node_id, target=target,
                            mtype=mtype,
                            reason=MigrationReason.MEMORY_PRESSURE,
                            urgency=1,
                            detail=f"RAM nœud {node.ram_used_pct:.0f}% (haute ≥ {t.ram_high_pct:.0f}%)",
                        ))

                # ── 4. Saturation vCPU ─────────────────────────────────────
                if (vm.throttle_ratio > t.vcpu_throttle_trigger
                        and node.vcpu_used_pct > t.vcpu_saturation_pct):
                    target = self._best_target_vcpu(node_id, node_states)
                    if target:
                        candidates.append(MigrationCandidate(
                            vm=vm, source=node_id, target=target,
                            mtype=MigrationType.LIVE,  # VM throttlée = active
                            reason=MigrationReason.CPU_SATURATION,
                            urgency=1,
                            detail=(
                                f"throttle {vm.throttle_ratio:.0%}, "
                                f"nœud {node.vcpu_used_pct:.0f}% vCPU"
                            ),
                        ))

        # Dédupliquer (une VM ne migre qu'une fois) et trier par urgence
        seen: set = set()
        unique: List[MigrationCandidate] = []
        for c in sorted(candidates, key=lambda x: -x.urgency):
            if c.vm.vm_id not in seen:
                seen.add(c.vm.vm_id)
                unique.append(c)

        return unique

    def pick_migration_type(
        self,
        vm: VmState,
        node_ram_pct: float,
    ) -> MigrationType:
        """
        API publique pour choisir le type de migration d'une VM spécifique.
        Utilisée par l'admin ou le controller pour une décision manuelle.
        """
        critical = node_ram_pct >= self.thresholds.ram_critical_pct
        return self._pick_type(vm, critical=critical)

    # ── Méthodes internes ─────────────────────────────────────────────────

    def _pick_type(self, vm: VmState, critical: bool) -> MigrationType:
        """
        Choisit entre LIVE et COLD selon l'état de la VM.

        COLD si :
          - VM stoppée
          - Pression critique (live trop lent, trop de dirty pages)
          - VM idle depuis > idle_duration_secs
        LIVE sinon (VM active → minimiser le downtime).
        """
        if vm.is_stopped:
            return MigrationType.COLD
        if critical:
            return MigrationType.COLD
        if self._is_idle(vm):
            return MigrationType.COLD
        return MigrationType.LIVE

    def _is_idle(self, vm: VmState) -> bool:
        t = self.thresholds
        return (
            vm.avg_cpu_pct < t.idle_cpu_pct
            and vm.idle_duration_secs() >= t.idle_duration_secs
        )

    def _best_target(
        self,
        source_id: str,
        vm: VmState,
        nodes: Dict[str, NodeState],
    ) -> Optional[str]:
        """Retourne le meilleur nœud cible (hors source) pour la VM."""
        eligible = [
            (nid, n) for nid, n in nodes.items()
            if nid != source_id and n.can_accept_vm(vm)
        ]
        if not eligible:
            return None
        # Meilleur score composite (RAM × 60% + vCPU × 40%)
        return max(eligible, key=lambda x: x[1].placement_score())[0]

    def _best_target_vcpu(
        self,
        source_id: str,
        nodes: Dict[str, NodeState],
    ) -> Optional[str]:
        """Retourne le nœud avec le plus de vCPU libres."""
        eligible = [
            (nid, n) for nid, n in nodes.items()
            if nid != source_id
            and n.vcpu_used_pct < self.thresholds.target_max_vcpu_pct
        ]
        if not eligible:
            return None
        return max(eligible, key=lambda x: x[1].vcpu_free)[0]
