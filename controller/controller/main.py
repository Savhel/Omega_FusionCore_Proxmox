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
from typing import Dict, List, Optional

import click
import requests
import structlog

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
@click.option("--dry-run", is_flag=True, default=False,
              help="Évalue et journalise les recommandations sans déclencher les migrations")
def daemon(
    node_a: str,
    node_b: str,
    node_c: str,
    poll_interval: int,
    max_concurrent_migrations: int,
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

    log.info(
        "daemon de migration démarré",
        nodes=list(node_urls.keys()),
        poll_interval_s=poll_interval,
        dry_run=dry_run,
    )

    while True:
        try:
            node_states = _fetch_cluster_state(node_urls)
            if node_states:
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
                        _execute_migrations(candidates[:max_concurrent_migrations], node_urls)
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
                ))

            mem_total_kb      = node_data.get("mem_total_kb", 0)
            mem_available_kb  = node_data.get("mem_available_kb", 0)
            vcpu_total        = node_data.get("vcpu_total", 24)
            vcpu_free         = node_data.get("vcpu_free", 24)

            states[node_id] = MigNodeState(
                node_id          = node_id,
                mem_total_kb     = mem_total_kb,
                mem_available_kb = mem_available_kb,
                vcpu_total       = vcpu_total,
                vcpu_free        = vcpu_free,
                local_vms        = vms,
            )
        except requests.RequestException as exc:
            log.warning("nœud injoignable", node_id=node_id, url=url, error=str(exc))

    return states


def _execute_migrations(
    candidates: List[MigrationCandidate],
    node_urls: Dict[str, str],
) -> None:
    """Appelle POST /control/migrate pour chaque candidat."""
    for c in candidates:
        source_url = node_urls.get(c.source)
        if not source_url:
            log.error("nœud source inconnu", source=c.source)
            continue

        url = source_url.rstrip("/") + "/control/migrate"
        payload = c.to_api_payload()
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
