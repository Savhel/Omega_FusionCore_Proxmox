from controller import main
from controller.migration_policy import NodeState, VmState


class FakeResponse:
    def __init__(self, payload, status_code=200):
        self._payload = payload
        self.status_code = status_code

    def json(self):
        return self._payload

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"http {self.status_code}")


def make_vm() -> VmState:
    return VmState(
        vm_id=101,
        status="running",
        max_mem_mib=2048,
        rss_kb=0,
        remote_pages=0,
        avg_cpu_pct=0.0,
        throttle_ratio=0.0,
        gpu_vram_budget_mib=0,
    )


def make_node(node_id: str, vcpu_free: int) -> NodeState:
    return NodeState(
        node_id=node_id,
        mem_total_kb=16 * 1024 * 1024,
        mem_available_kb=12 * 1024 * 1024,
        vcpu_total=12,
        vcpu_free=vcpu_free,
        gpu_total_vram_mib=0,
        gpu_free_vram_mib=0,
        local_vms=[],
    )


def test_reconcile_uses_real_proxmox_node_name(monkeypatch):
    proxmox_calls = []

    class FakeAdmission:
        pass

    class FakeProxmox:
        def get_vm_config(self, node, vmid):
            proxmox_calls.append((node, vmid))
            return {}

        def parse_omega_metadata(self, config):
            return config

    monkeypatch.setattr(main, "_fetch_vm_quota", lambda source_url, vm_id: {"quota": "ok"})
    monkeypatch.setattr(main, "_ensure_vm_gpu_budget", lambda **kwargs: None)
    monkeypatch.setattr(main, "_ensure_vm_vcpu_profile", lambda **kwargs: None)

    vm = make_vm()
    node = make_node("node-a", vcpu_free=2)
    node.proxmox_node_name = "pve"
    node.local_vms = [vm]

    main._reconcile_cluster_resources(
        node_urls={"node-a": "http://node-a:9300"},
        node_states={"node-a": node},
        admission=FakeAdmission(),
        proxmox=FakeProxmox(),
        dry_run=False,
    )

    assert proxmox_calls == [("pve", 101)]


def test_reconcile_stops_after_reposition_request(monkeypatch):
    class FakeDecision:
        admitted = True
        placement_node = "node-c"
        reason = ""

        @staticmethod
        def quota_payload():
            return {"local_budget_mib": 1536, "remote_budget_mib": 512}

    class FakeAdmission:
        def admit(self, cluster, spec):
            return FakeDecision()

    class FakeProxmox:
        def get_vm_config(self, node, vmid):
            raise AssertionError("should not fetch config when relocation is pending")

        def parse_omega_metadata(self, config):
            return config

    posts = []

    def fake_post(url, json, timeout):
        posts.append((url, json))
        return FakeResponse({"status": "ok"})

    monkeypatch.setattr(main, "_fetch_vm_quota", lambda source_url, vm_id: None)
    monkeypatch.setattr(main.requests, "post", fake_post)

    vm = make_vm()
    source = make_node("node-a", vcpu_free=2)
    source.proxmox_node_name = "pve"
    source.local_vms = [vm]
    target = make_node("node-c", vcpu_free=8)
    target.proxmox_node_name = "pve3"

    main._reconcile_cluster_resources(
        node_urls={"node-a": "http://node-a:9300", "node-c": "http://node-c:9300"},
        node_states={"node-a": source, "node-c": target},
        admission=FakeAdmission(),
        proxmox=FakeProxmox(),
        dry_run=False,
    )

    assert posts == [
        (
            "http://node-a:9300/control/migrate",
            {"vm_id": 101, "target": "pve3", "type": "live"},
        )
    ]


def test_ensure_vm_vcpu_profile_posts_profile_update(monkeypatch):
    calls = []

    def fake_get(url, timeout):
        assert url.endswith("/control/vcpu/status")
        return FakeResponse({
            "vm_states": [
                {"vm_id": 101, "current_vcpus": 1, "min_vcpus": 1, "max_vcpus": 2}
            ]
        })

    def fake_post(url, json, timeout):
        calls.append((url, json))
        return FakeResponse({"status": "ok"})

    monkeypatch.setattr(main.requests, "get", fake_get)
    monkeypatch.setattr(main.requests, "post", fake_post)

    assert main._ensure_vm_vcpu_profile(
        source_node="node-a",
        source_url="http://node-a:9300",
        vm=make_vm(),
        metadata={"min_vcpus": 2, "max_vcpus": 4},
        node_states={
            "node-a": make_node("node-a", vcpu_free=2),
            "node-b": make_node("node-b", vcpu_free=4),
        },
        gpu_budget_mib=0,
        dry_run=False,
    ) is False

    assert calls == [
        (
            "http://node-a:9300/control/vm/101/vcpu",
            {"min_vcpus": 2, "max_vcpus": 4},
        )
    ]


def test_ensure_vm_vcpu_profile_migrates_when_source_is_too_full(monkeypatch):
    calls = []

    def fake_get(url, timeout):
        assert url.endswith("/control/vcpu/status")
        return FakeResponse({
            "vm_states": [
                {"vm_id": 101, "current_vcpus": 1, "min_vcpus": 1, "max_vcpus": 2}
            ]
        })

    def fake_post(url, json, timeout):
        calls.append((url, json))
        return FakeResponse({"status": "ok"})

    monkeypatch.setattr(main.requests, "get", fake_get)
    monkeypatch.setattr(main.requests, "post", fake_post)

    source = make_node("node-a", vcpu_free=1)
    source.proxmox_node_name = "pve1"
    target = make_node("node-b", vcpu_free=4)
    target.proxmox_node_name = "pve2"

    assert main._ensure_vm_vcpu_profile(
        source_node="node-a",
        source_url="http://node-a:9300",
        vm=make_vm(),
        metadata={"min_vcpus": 3, "max_vcpus": 4},
        node_states={
            "node-a": source,
            "node-b": target,
        },
        gpu_budget_mib=0,
        dry_run=False,
    ) is True

    assert calls == [
        (
            "http://node-a:9300/control/migrate",
            {"vm_id": 101, "target": "pve2", "type": "live"},
        )
    ]
