"""
Point d'entrée CLI du controller omega-remote-paging.

Usage :
    python -m controller.main monitor --interval 10
    python -m controller.main status
    python -m controller.main policy --dry-run
"""

from __future__ import annotations

import json
import time
import sys
import logging
from typing import Dict, List, Optional, Tuple

import click
import requests
import structlog

from .admission import AdmissionController, VmSpec
from .cluster import ClusterState, NodeInfo, VmEntry
from .metrics import MetricsCollector
from .migration_policy import (
    MigrationCandidate,
    MigrationPolicy,
    MigrationThresholds,
    NodeState as MigNodeState,
    VmState,
)
from .policy import PolicyEngine, PolicyInput, Decision
from .proxmox import ProxmoxClient
from .store_client import poll_all_stores

# ─── Configuration du logging structuré ───────────────────────────────────────

def setup_logging(level: str = "INFO", fmt: str = "console") -> None:
    logging.basicConfig(
        level  = getattr(logging, level.upper(), logging.INFO),
        stream = sys.stderr,
    )

    if fmt == "json":
        structlog.configure(
            processors=[
                structlog.processors.TimeStamper(fmt="iso"),
                structlog.processors.add_log_level,
                structlog.processors.JSONRenderer(),
            ],
            wrapper_class=structlog.make_filtering_bound_logger(logging.INFO),
            logger_factory=structlog.PrintLoggerFactory(),
        )
    else:
        structlog.configure(
            processors=[
                structlog.processors.TimeStamper(fmt="%H:%M:%S"),
                structlog.processors.add_log_level,
                structlog.dev.ConsoleRenderer(),
            ],
            wrapper_class=structlog.make_filtering_bound_logger(logging.INFO),
            logger_factory=structlog.PrintLoggerFactory(),
        )


log = structlog.get_logger()

# ─── Groupe CLI principal ──────────────────────────────────────────────────────

@click.group()
@click.option("--log-level",  default="INFO",    show_default=True, help="Niveau de log")
@click.option("--log-format", default="console", show_default=True, help="Format : console ou json")
@click.pass_context
def cli(ctx: click.Context, log_level: str, log_format: str) -> None:
    """Controller de politique de paging distant — cluster omega-remote-paging (3 nœuds)."""
    setup_logging(log_level, log_format)
    ctx.ensure_object(dict)
    ctx.obj["log_level"]  = log_level
    ctx.obj["log_format"] = log_format


# ─── Commande : status ────────────────────────────────────────────────────────

@cli.command()
@click.option("--stores", default="127.0.0.1:9100,127.0.0.1:9101",
              help="Adresses des stores (host:port séparés par des virgules)")
@click.option("--proxmox-url", default="", help="URL de base Proxmox VE API (optionnel)")
def status(stores: str, proxmox_url: str) -> None:
    """Affiche le statut des stores et la situation mémoire locale."""
    collector = MetricsCollector()
    proxmox   = ProxmoxClient(base_url=proxmox_url or "https://proxmox-a:8006")

    # Métriques locales
    mem_snap = collector.snapshot()
    log.info("métriques mémoire locales", **mem_snap)

    # Statut des stores
    store_list = [s.strip() for s in stores.split(",") if s.strip()]
    log.info("interrogation des stores", count=len(store_list))
    statuses = poll_all_stores(store_list)
    for s in statuses:
        log.info(
            "store status",
            addr      = s.addr,
            reachable = s.reachable,
            stats     = s.stats,
        )

    # Vue cluster Proxmox (stub V1)
    cluster_summary = proxmox.cluster_memory_summary()
    log.info("résumé cluster (stub V1)", **cluster_summary)


# ─── Commande : policy ────────────────────────────────────────────────────────

@cli.command()
@click.option("--threshold-enable",  default=70.0, show_default=True,
              help="% RAM pour activer le remote paging")
@click.option("--threshold-migrate", default=90.0, show_default=True,
              help="% RAM pour recommander la migration")
@click.option("--dry-run", is_flag=True, default=False,
              help="Affiche la décision sans l'exécuter")
def policy(threshold_enable: float, threshold_migrate: float, dry_run: bool) -> None:
    """Évalue la politique de paging et affiche la décision."""
    collector = MetricsCollector()
    engine    = PolicyEngine(
        threshold_enable_pct  = threshold_enable,
        threshold_migrate_pct = threshold_migrate,
    )
    proxmox = ProxmoxClient()

    mem      = collector.read_meminfo()
    pressure = collector.read_pressure()

    inp    = PolicyInput(mem=mem, pressure=pressure)
    result = engine.evaluate(inp)

    log.info(
        "décision de politique",
        decision   = result.decision.value,
        reason     = result.reason,
        confidence = result.confidence,
        mem_usage  = f"{mem.usage_pct:.1f}%",
        swap_usage = f"{mem.swap_usage_pct:.1f}%",
    )

    if dry_run:
        log.info("mode dry-run — aucune action exécutée")
        return

    # Exécution de la décision
    _execute_decision(result.decision, proxmox)


# ─── Commande : monitor ───────────────────────────────────────────────────────

@cli.command()
@click.option("--interval", default=10, show_default=True, help="Intervalle en secondes")
@click.option("--stores",   default="127.0.0.1:9100,127.0.0.1:9101",
              help="Adresses des stores")
@click.option("--threshold-enable",  default=70.0, show_default=True)
@click.option("--threshold-migrate", default=90.0, show_default=True)
def monitor(
    interval:          int,
    stores:            str,
    threshold_enable:  float,
    threshold_migrate: float,
) -> None:
    """Boucle de monitoring : collecte, évalue, journalise en continu."""
    collector  = MetricsCollector()
    engine     = PolicyEngine(threshold_enable, threshold_migrate)
    proxmox    = ProxmoxClient()
    store_list = [s.strip() for s in stores.split(",") if s.strip()]

    log.info(
        "démarrage du monitoring",
        interval_s         = interval,
        stores             = store_list,
        policy_thresholds  = engine.describe_thresholds(),
    )

    prev_decision: Optional[Decision] = None

    while True:
        try:
            mem      = collector.read_meminfo()
            pressure = collector.read_pressure()
            inp      = PolicyInput(mem=mem, pressure=pressure)
            result   = engine.evaluate(inp)

            psi_some = pressure.some_avg10 if pressure else 0.0
            psi_full = pressure.full_avg10 if pressure else 0.0

            log.info(
                "cycle monitoring",
                mem_usage_pct  = round(mem.usage_pct, 1),
                swap_usage_pct = round(mem.swap_usage_pct, 1),
                psi_some_avg10 = psi_some,
                psi_full_avg10 = psi_full,
                decision       = result.decision.value,
                reason         = result.reason,
            )

            # Log de changement de décision (transition d'état)
            if result.decision != prev_decision:
                log.warning(
                    "changement de décision",
                    old = prev_decision.value if prev_decision else "initial",
                    new = result.decision.value,
                )
                prev_decision = result.decision

            # Statut des stores (toutes les N itérations en V2, ici à chaque cycle)
            store_statuses = poll_all_stores(store_list, timeout=1.0)
            for s in store_statuses:
                if not s.reachable:
                    log.warning("store injoignable", addr=s.addr)

        except KeyboardInterrupt:
            log.info("monitoring arrêté par l'utilisateur")
            break
        except Exception as e:
            log.error("erreur cycle monitoring", error=str(e))

        time.sleep(interval)


# ─── Commande : daemon ───────────────────────────────────────────────────────

@cli.command()
@click.option("--node-a", required=True, help="URL API contrôle nœud A (ex: http://192.168.10.1:9300)")
@click.option("--node-b", required=True, help="URL API contrôle nœud B")
@click.option("--node-c", required=True, help="URL API contrôle nœud C")
@click.option("--poll-interval", default=5, show_default=True, help="Intervalle de polling en secondes")
@click.option("--max-concurrent-migrations", default=1, show_default=True,
              help="Nombre maximum de migrations simultanées par cycle")
@click.option("--proxmox-url", default="https://127.0.0.1:8006", show_default=True,
              help="URL Proxmox VE API utilisée pour lire la configuration VM")
@click.option("--proxmox-token", default="", help="Token Proxmox VE API (sinon mode stub)")
@click.option("--auto-admit/--no-auto-admit", default=True, show_default=True,
              help="Configure automatiquement quotas et budgets des nouvelles VMs")
@click.option("--dry-run", is_flag=True, default=False,
              help="Évalue et journalise les recommandations sans déclencher les migrations")
def daemon(
    node_a: str,
    node_b: str,
    node_c: str,
    poll_interval: int,
    max_concurrent_migrations: int,
    proxmox_url: str,
    proxmox_token: str,
    auto_admit: bool,
    dry_run: bool,
) -> None:
    """
    Daemon de migration automatique : surveille le cluster et déclenche
    les migrations live/cold au moment optimal.

    Appelle GET /control/status sur chaque nœud, évalue MigrationPolicy,
    puis POST /control/migrate sur le nœud source pour chaque recommandation.
    """
    node_urls: Dict[str, str] = {
        "node-a": node_a.rstrip("/"),
        "node-b": node_b.rstrip("/"),
        "node-c": node_c.rstrip("/"),
    }
    policy = MigrationPolicy(MigrationThresholds())
    admission = AdmissionController()
    proxmox = ProxmoxClient(base_url=proxmox_url, api_token=proxmox_token)

    log.info(
        "daemon de migration démarré",
        nodes=list(node_urls.keys()),
        poll_interval_s=poll_interval,
        auto_admit=auto_admit,
        dry_run=dry_run,
    )

    while True:
        try:
            node_states = _fetch_cluster_state(node_urls)
            if node_states:
                if auto_admit:
                    _reconcile_cluster_resources(
                        node_urls=node_urls,
                        node_states=node_states,
                        admission=admission,
                        proxmox=proxmox,
                        dry_run=dry_run,
                    )
                candidates = policy.evaluate(node_states)
                if candidates:
                    log.info(
                        "migrations recommandées",
                        count=len(candidates),
                        candidates=[
                            {
                                "vm_id": c.vm.vm_id,
                                "source": c.source,
                                "target": c.target,
                                "type": c.mtype.value,
                                "urgency": c.urgency,
                                "detail": c.detail,
                            }
                            for c in candidates
                        ],
                    )
                    if not dry_run:
                        _execute_migrations(
                            candidates[:max_concurrent_migrations],
                            node_urls,
                            node_states,
                        )
                else:
                    log.debug("aucune migration nécessaire")

        except KeyboardInterrupt:
            log.info("daemon arrêté par l'utilisateur")
            break
        except Exception as e:
            log.error("erreur cycle daemon", error=str(e))

        time.sleep(poll_interval)


# ─── Commande : migrate ──────────────────────────────────────────────────────

@cli.command()
@click.option("--source", required=True,
              help="URL API contrôle nœud source (ex: http://192.168.10.1:9300)")
@click.option("--vm-id",  required=True, type=int, help="ID de la VM à migrer")
@click.option("--target", required=True, help="ID du nœud cible (ex: node-b)")
@click.option("--type",   "mtype", default="live", show_default=True,
              type=click.Choice(["live", "cold"]), help="Type de migration")
def migrate(source: str, vm_id: int, target: str, mtype: str) -> None:
    """Déclenche manuellement une migration live ou cold via l'API contrôle."""
    url = source.rstrip("/") + "/control/migrate"
    payload = {"vm_id": vm_id, "target": target, "type": mtype}

    log.info("déclenchement migration manuelle", **payload, url=url)
    try:
        resp = requests.post(url, json=payload, timeout=10)
        resp.raise_for_status()
        data = resp.json()
        log.info("migration démarrée", task_id=data.get("task_id"), response=data)
    except requests.RequestException as exc:
        log.error("échec appel API migration", url=url, error=str(exc))
        sys.exit(1)


# ─── Helpers privés ───────────────────────────────────────────────────────────

def _fetch_cluster_state(node_urls: Dict[str, str]) -> Dict[str, MigNodeState]:
    """
    Interroge GET /control/status sur chaque nœud et construit
    les NodeState utilisés par MigrationPolicy.

    Les nœuds injoignables sont ignorés (logged comme warning).
    """
    states: Dict[str, MigNodeState] = {}

    for node_id, base_url in node_urls.items():
        url = base_url + "/control/status"
        try:
            resp = requests.get(url, timeout=3)
            resp.raise_for_status()
            data = resp.json()
            node_data = data.get("node", data)  # /control/status wraps under "node"
            gpu_data = node_data.get("gpu") or {}

            vms: List[VmState] = []
            for vm_entry in node_data.get("local_vms", []):
                vms.append(VmState(
                    vm_id          = vm_entry["vmid"],
                    status         = vm_entry.get("status", "unknown"),
                    max_mem_mib    = vm_entry.get("max_mem_mib", 0),
                    rss_kb         = vm_entry.get("rss_kb", 0),
                    remote_pages   = vm_entry.get("remote_pages", 0),
                    avg_cpu_pct    = vm_entry.get("avg_cpu_pct", 0.0),
                    throttle_ratio = vm_entry.get("throttle_ratio", 0.0),
                    gpu_vram_budget_mib = vm_entry.get("gpu_vram_budget_mib", 0),
                ))

            mem_total_kb      = node_data.get("mem_total_kb", 0)
            mem_available_kb  = node_data.get("mem_available_kb", 0)
            vcpu_total        = node_data.get("vcpu_total", 24)
            vcpu_free         = node_data.get("vcpu_free", 24)

            states[node_id] = MigNodeState(
                node_id          = node_id,
                mem_total_kb     = mem_total_kb,
                mem_available_kb = mem_available_kb,
                proxmox_node_name = node_data.get("node_id", node_id),
                vcpu_total       = vcpu_total,
                vcpu_free        = vcpu_free,
                gpu_total_vram_mib = gpu_data.get("total_vram_mib", 0),
                gpu_free_vram_mib = gpu_data.get("free_vram_mib", 0),
                local_vms        = vms,
            )
        except requests.RequestException as exc:
            log.warning("nœud injoignable", node_id=node_id, url=url, error=str(exc))

    return states


def _build_cluster_state(node_states: Dict[str, MigNodeState], node_urls: Dict[str, str]) -> ClusterState:
    nodes: List[NodeInfo] = []
    for node_id, state in node_states.items():
        vms = [
            VmEntry(
                vmid=vm.vm_id,
                max_mem_mib=vm.max_mem_mib,
                rss_kb=vm.rss_kb,
                remote_pages=vm.remote_pages,
                remote_mem_mib=vm.remote_pages * 4 // 1024,
                status=vm.status,
                gpu_vram_budget_mib=vm.gpu_vram_budget_mib,
            )
            for vm in state.local_vms
        ]
        nodes.append(NodeInfo(
            node_id=node_id,
            store_addr="",
            api_addr=node_urls[node_id],
            mem_total_kb=state.mem_total_kb,
            mem_available_kb=state.mem_available_kb,
            mem_usage_pct=state.ram_used_pct,
            pages_stored=0,
            store_used_kb=0,
            local_vms=vms,
            timestamp_secs=int(time.time()),
            gpu_enabled=state.gpu_total_vram_mib > 0,
            gpu_total_vram_mib=state.gpu_total_vram_mib,
            gpu_free_vram_mib=state.gpu_free_vram_mib,
            gpu_reserved_vram_mib=max(0, state.gpu_total_vram_mib - state.gpu_free_vram_mib),
            gpu_backend_name="",
            reachable=True,
        ))
    return ClusterState(nodes=nodes)


def _reconcile_cluster_resources(
    node_urls: Dict[str, str],
    node_states: Dict[str, MigNodeState],
    admission: AdmissionController,
    proxmox: ProxmoxClient,
    dry_run: bool,
) -> None:
    cluster = _build_cluster_state(node_states, node_urls)

    for node_id, node_state in node_states.items():
        source_url = node_urls[node_id]
        for vm in node_state.local_vms:
            quota = _fetch_vm_quota(source_url, vm.vm_id)
            if quota is None:
                if _ensure_vm_admitted(
                    source_node=node_id,
                    source_url=source_url,
                    vm=vm,
                    cluster=cluster,
                    admission=admission,
                    node_states=node_states,
                    dry_run=dry_run,
                ):
                    continue

            proxmox_node_name = node_state.proxmox_node_name or node_id
            config = proxmox.get_vm_config(proxmox_node_name, vm.vm_id)
            metadata = proxmox.parse_omega_metadata(config)
            gpu_budget = metadata.get("gpu_vram_mib", 0) or 0
            if gpu_budget > 0 and vm.gpu_vram_budget_mib != gpu_budget:
                _ensure_vm_gpu_budget(
                    source_url=source_url,
                    vm_id=vm.vm_id,
                    gpu_budget_mib=gpu_budget,
                    dry_run=dry_run,
                )

            if _ensure_vm_vcpu_profile(
                source_node=node_id,
                source_url=source_url,
                vm=vm,
                metadata=metadata,
                node_states=node_states,
                gpu_budget_mib=gpu_budget or vm.gpu_vram_budget_mib,
                dry_run=dry_run,
            ):
                continue


def _fetch_vm_quota(source_url: str, vm_id: int) -> Optional[dict]:
    url = source_url.rstrip("/") + f"/control/vm/{vm_id}/quota"
    try:
        resp = requests.get(url, timeout=3)
        if resp.status_code == 404:
            return None
        resp.raise_for_status()
        return resp.json().get("quota")
    except requests.RequestException:
        return None


def _fetch_vcpu_status(source_url: str) -> Optional[dict]:
    url = source_url.rstrip("/") + "/control/vcpu/status"
    try:
        resp = requests.get(url, timeout=3)
        resp.raise_for_status()
        return resp.json()
    except requests.RequestException:
        return None


def _normalize_vcpu_profile(metadata: dict) -> Optional[Tuple[int, int]]:
    desired_min = metadata.get("min_vcpus")
    desired_max = metadata.get("max_vcpus")

    if desired_min is None and desired_max is None:
        return None

    if desired_min is None:
        desired_min = desired_max
    if desired_max is None:
        desired_max = desired_min

    desired_min = max(1, int(desired_min or 1))
    desired_max = max(desired_min, int(desired_max or desired_min))
    return desired_min, desired_max


def _target_can_host_vm(
    node_state: MigNodeState,
    vm: VmState,
    required_vcpus: int,
    gpu_budget_mib: int,
) -> bool:
    if node_state.vcpu_free < required_vcpus:
        return False
    if vm.max_mem_mib > 0 and node_state.mem_available_kb < vm.max_mem_mib * 1024:
        return False
    if gpu_budget_mib > 0 and node_state.gpu_free_vram_mib < gpu_budget_mib:
        return False
    return True


def _best_reconciliation_target(
    source_node: str,
    vm: VmState,
    node_states: Dict[str, MigNodeState],
    required_vcpus: int,
    gpu_budget_mib: int,
) -> Optional[str]:
    candidates = [
        state
        for node_id, state in node_states.items()
        if node_id != source_node
        and _target_can_host_vm(state, vm, required_vcpus, gpu_budget_mib)
    ]
    if not candidates:
        return None

    candidates.sort(
        key=lambda state: (
            state.vcpu_free,
            state.mem_available_kb,
            state.gpu_free_vram_mib,
        ),
        reverse=True,
    )
    return candidates[0].node_id


def _proxmox_target_name(node_states: Dict[str, MigNodeState], target_node: str) -> str:
    state = node_states.get(target_node)
    if state is None:
        return target_node
    return state.proxmox_node_name or target_node


def _ensure_vm_admitted(
    source_node: str,
    source_url: str,
    vm: VmState,
    cluster: ClusterState,
    admission: AdmissionController,
    node_states: Dict[str, MigNodeState],
    dry_run: bool,
) -> bool:
    decision = admission.admit(cluster, VmSpec(vmid=vm.vm_id, max_mem_mib=vm.max_mem_mib))
    if not decision.admitted:
        log.warning(
            "admission automatique impossible",
            vm_id=vm.vm_id,
            source=source_node,
            reason=decision.reason,
        )
        return False

    if decision.placement_node and decision.placement_node != source_node:
        proxmox_target = _proxmox_target_name(node_states, decision.placement_node)
        log.warning(
            "repositionnement automatique de VM",
            vm_id=vm.vm_id,
            source=source_node,
            target=decision.placement_node,
            proxmox_target=proxmox_target,
        )
        if dry_run:
            return True
        payload = {
            "vm_id": vm.vm_id,
            "target": proxmox_target,
            "type": "live" if vm.status == "running" else "cold",
        }
        try:
            resp = requests.post(source_url.rstrip("/") + "/control/migrate", json=payload, timeout=10)
            resp.raise_for_status()
        except requests.RequestException as exc:
            log.error("échec repositionnement automatique", vm_id=vm.vm_id, error=str(exc))
        return True

    payload = decision.quota_payload()
    log.info(
        "configuration automatique du quota",
        vm_id=vm.vm_id,
        node=source_node,
        local_budget_mib=payload["local_budget_mib"],
        remote_budget_mib=payload["remote_budget_mib"],
    )
    if dry_run:
        return
    try:
        resp = requests.post(
            source_url.rstrip("/") + f"/control/vm/{vm.vm_id}/quota",
            json=payload,
            timeout=10,
        )
        resp.raise_for_status()
    except requests.RequestException as exc:
        log.error("échec configuration quota automatique", vm_id=vm.vm_id, error=str(exc))
    return False


def _ensure_vm_gpu_budget(
    source_url: str,
    vm_id: int,
    gpu_budget_mib: int,
    dry_run: bool,
) -> None:
    log.info(
        "configuration automatique du budget GPU",
        vm_id=vm_id,
        gpu_budget_mib=gpu_budget_mib,
    )
    if dry_run:
        return
    try:
        resp = requests.post(
            source_url.rstrip("/") + f"/control/vm/{vm_id}/gpu",
            json={"vram_budget_mib": gpu_budget_mib},
            timeout=10,
        )
        resp.raise_for_status()
    except requests.RequestException as exc:
        log.error("échec configuration budget GPU automatique", vm_id=vm_id, error=str(exc))


def _ensure_vm_vcpu_profile(
    source_node: str,
    source_url: str,
    vm: VmState,
    metadata: dict,
    node_states: Dict[str, MigNodeState],
    gpu_budget_mib: int,
    dry_run: bool,
) -> bool:
    profile = _normalize_vcpu_profile(metadata)
    if profile is None:
        return False

    desired_min, desired_max = profile
    vcpu_status = _fetch_vcpu_status(source_url) or {}
    current_state = next(
        (
            entry for entry in vcpu_status.get("vm_states", [])
            if entry.get("vm_id") == vm.vm_id
        ),
        None,
    )

    current_vcpus = int(current_state.get("current_vcpus", 0)) if current_state else 0
    current_min = int(current_state.get("min_vcpus", current_vcpus)) if current_state else 0
    current_max = int(current_state.get("max_vcpus", current_vcpus)) if current_state else 0

    if current_state and current_min == desired_min and current_max == desired_max:
        return False

    required_extra = max(0, desired_min - current_vcpus)
    source_state = node_states[source_node]
    if source_state.vcpu_free < required_extra:
        target = _best_reconciliation_target(
            source_node=source_node,
            vm=vm,
            node_states=node_states,
            required_vcpus=desired_min,
            gpu_budget_mib=gpu_budget_mib,
        )
        if not target:
            log.warning(
                "profil vCPU automatique impossible",
                vm_id=vm.vm_id,
                source=source_node,
                min_vcpus=desired_min,
                max_vcpus=desired_max,
            )
            return False

        proxmox_target = _proxmox_target_name(node_states, target)
        log.warning(
            "migration automatique pour satisfaire le profil vCPU",
            vm_id=vm.vm_id,
            source=source_node,
            target=target,
            proxmox_target=proxmox_target,
            min_vcpus=desired_min,
            max_vcpus=desired_max,
        )
        if dry_run:
            return True
        payload = {
            "vm_id": vm.vm_id,
            "target": proxmox_target,
            "type": "live" if vm.status == "running" else "cold",
        }
        try:
            resp = requests.post(source_url.rstrip("/") + "/control/migrate", json=payload, timeout=10)
            resp.raise_for_status()
        except requests.RequestException as exc:
            log.error("échec migration automatique CPU", vm_id=vm.vm_id, error=str(exc))
        return True

    log.info(
        "configuration automatique du profil vCPU",
        vm_id=vm.vm_id,
        min_vcpus=desired_min,
        max_vcpus=desired_max,
    )
    if dry_run:
        return
    try:
        resp = requests.post(
            source_url.rstrip("/") + f"/control/vm/{vm.vm_id}/vcpu",
            json={"min_vcpus": desired_min, "max_vcpus": desired_max},
            timeout=10,
        )
        resp.raise_for_status()
    except requests.RequestException as exc:
        log.error("échec configuration vCPU automatique", vm_id=vm.vm_id, error=str(exc))
    return False


def _execute_migrations(
    candidates: List[MigrationCandidate],
    node_urls: Dict[str, str],
    node_states: Dict[str, MigNodeState],
) -> None:
    """Appelle POST /control/migrate pour chaque candidat."""
    for c in candidates:
        source_url = node_urls.get(c.source)
        if not source_url:
            log.error("nœud source inconnu", source=c.source)
            continue

        url = source_url.rstrip("/") + "/control/migrate"
        payload = c.to_api_payload()
        payload["target"] = _proxmox_target_name(node_states, c.target)
        try:
            resp = requests.post(url, json=payload, timeout=10)
            resp.raise_for_status()
            data = resp.json()
            log.info(
                "migration déclenchée",
                vm_id   = c.vm.vm_id,
                source  = c.source,
                target  = c.target,
                type    = c.mtype.value,
                task_id = data.get("task_id"),
            )
        except requests.RequestException as exc:
            log.error(
                "échec déclenchement migration",
                vm_id  = c.vm.vm_id,
                source = c.source,
                error  = str(exc),
            )


def _execute_decision(decision: Decision, proxmox: ProxmoxClient) -> None:
    """
    Exécute la décision prise par la politique.

    V1 : journalisation seulement pour migrate (l'API Proxmox est un stub).
    V2 : appels API réels.
    """
    if decision == Decision.LOCAL_ONLY:
        log.info("action : rien (mémoire suffisante)")

    elif decision == Decision.ENABLE_REMOTE:
        log.info(
            "action : remote paging activé",
            note="en V1 l'agent active le paging automatiquement — aucune commande à envoyer",
        )

    elif decision == Decision.MIGRATE:
        best_node = proxmox.get_node_with_most_free_ram(exclude_node="node-a")
        log.warning(
            "action : migration recommandée (stub V1)",
            target_node = best_node,
            note        = "migration non exécutée en V1 — implémenter proxmox.migrate_vm() en V2",
        )


if __name__ == "__main__":
    cli()
