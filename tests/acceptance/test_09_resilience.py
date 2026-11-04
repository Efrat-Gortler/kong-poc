"""9. Dependencies down.
- Blocking service down: existing blocks keep working (Lua: last list in memory,
  OPA: last bundle); new blocks cannot be added. Traffic keeps flowing.
- Redis down: record what each rate-limit plugin does (documented, not asserted).
Scales Deployments to 0 and back, so it only runs with -m destructive.
"""
import time

import pytest
import requests

from conftest import BLOCKING_URL, LEGS, blocking_mode, oc, wait_until


def scale(ns, kind_name, replicas):
    oc("scale", kind_name, "-n", ns, f"--replicas={replicas}")


def pause_argocd_selfheal(app: str, pause: bool):
    """ArgoCD would undo the scale-down; switch self-heal off meanwhile - on the root
    app first (it owns the child Application objects and would revert the patch)."""
    patch = '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":%s}}}}' % ("false" if pause else "true")
    order = ["kong-poc-root", app] if pause else [app, "kong-poc-root"]
    for name in order:
        oc("patch", "application", name, "-n", "openshift-gitops", "--type=merge", "-p", patch)


@pytest.mark.destructive
def test_blocking_service_down_keeps_existing_blocks(gslb, blocking, record):
    mode = blocking_mode()
    b = blocking.create("user", caller_id="666efratg@corp.local", reason="resilience test")
    wait_until(lambda: all(gslb.request("/orders/1", who="666efratg", leg=l).status_code == 403 for l in LEGS),
               timeout=60, interval=0.5)
    pause_argocd_selfheal("blocking-service", True)
    try:
        scale("blocking", "deploy/blocking-service", 0)
        wait_until(lambda: oc("get", "pods", "-n", "blocking", "-l", "app.kubernetes.io/name=blocking-service",
                              "-o", "name").strip() == "", timeout=120, what="blocking service stopped")
        time.sleep(15)  # several poll intervals fail meanwhile
        still_blocked = {l: gslb.request("/orders/1", who="666efratg", leg=l).status_code for l in LEGS}
        others_ok = {l: gslb.request("/orders/1", who="normaluser", leg=l).status_code for l in LEGS}
        try:
            r = requests.post(f"{BLOCKING_URL}/api/blocks", json={"kind": "user", "callerId": "x", "reason": "x"},
                              headers={"Authorization": f"Bearer {blocking.tokens.get('opsadmin')}"},
                              verify=False, timeout=10)
            create_status = r.status_code
        except requests.RequestException as e:
            create_status = f"error: {type(e).__name__}"
        record("blocking_service_down", {"mode": mode, "blocked_user": still_blocked,
                                         "other_user": others_ok, "create_block": create_status})
        assert set(still_blocked.values()) == {403}, "existing block lost while the service was down"
        assert set(others_ok.values()) == {200}, "traffic affected by the blocking service outage"
        assert create_status != 201
    finally:
        scale("blocking", "deploy/blocking-service", 1)
        oc("rollout", "status", "deploy/blocking-service", "-n", "blocking", "--timeout=180s")
        pause_argocd_selfheal("blocking-service", False)
        blocking.delete(b["id"])


@pytest.mark.destructive
def test_redis_down_behaviour_documented(gslb, record):
    pause_argocd_selfheal("redis", True)
    try:
        scale("gw-shared", "deploy/redis", 0)
        wait_until(lambda: oc("get", "pods", "-n", "gw-shared", "-l", "app.kubernetes.io/name=redis",
                              "-o", "name").strip() == "", timeout=120, what="redis stopped")
        time.sleep(3)
        observed = {}
        for name, path in [("route_limit_only (rate-limiting, fault_tolerant)", "/reports/limited/r"),
                           ("user_limit_only (rate-limiting-advanced)", "/users/limited/r"),
                           ("both plugins", "/orders/r")]:
            t0 = time.monotonic()
            r = gslb.request(path, who="normaluser", timeout=30)
            observed[name] = {"status": r.status_code, "seconds": round(time.monotonic() - t0, 2),
                              "body": r.text[:150]}
        record("redis_down", observed)
        # documented, not asserted: whatever happens must be understood (see TEST-REPORT.md)
    finally:
        scale("gw-shared", "deploy/redis", 1)
        oc("rollout", "status", "deploy/redis", "-n", "gw-shared", "--timeout=120s")
        pause_argocd_selfheal("redis", False)
