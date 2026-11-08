"""10. Config change via Git -> live in all legs, zero Kong pod restarts.
11. Drain a leg -> traffic continues on the others; the per-user limit stays exact.
12. New Kong pods serve the full config immediately."""
import os
import subprocess
import time

import pytest
import requests
import yaml

from conftest import KUBECTL, LEGS, REPO, gslb_control, oc, two_legs, wait_until


def kong_pods() -> dict[str, str]:
    """name -> uid:restarts of every Kong gateway/controller pod in every leg"""
    out = {}
    for leg in LEGS:
        for line in oc("get", "pods", "-n", leg, "-l", f"app.kubernetes.io/instance=kong-{leg}", "-o",
                       "jsonpath={range .items[*]}{.metadata.name} {.metadata.uid} "
                       "{range .status.containerStatuses[*]}{.restartCount},{end}{\"\\n\"}{end}").splitlines():
            if line.strip():
                name, uid, restarts = line.split(" ", 2)
                out[f"{leg}/{name}"] = f"{uid}:{restarts}"
    return out


def git(*args):
    subprocess.run(["git", "-C", str(REPO), *args], check=True, capture_output=True, text=True)


@pytest.mark.gitops
def test_10_git_change_live_everywhere_without_restarts(gslb, record):
    if os.environ.get("ALLOW_GIT_PUSH") != "1":
        pytest.skip("set ALLOW_GIT_PUSH=1 (pushes a temporary commit, then reverts it)")
    values = REPO / "charts/mock-service/values-orders.yaml"
    original = values.read_text()
    doc = yaml.safe_load(original)
    doc["kongRoutes"].append({"name": "orders-gitops-probe", "path": "/orders-probe", "service": "orders",
                              "port": 8080, "userLimitPerMinute": 7})
    before = kong_pods()
    try:
        values.write_text(yaml.safe_dump(doc, sort_keys=False))
        git("add", str(values))
        git("commit", "-m", "test(10): add a probe route with a new threshold")
        git("push")
        t0 = time.monotonic()
        # hard refresh so ArgoCD does not wait for its poll interval
        for leg in LEGS:
            oc("annotate", "application", f"{leg}-orders", "-n", "openshift-gitops",
               "argocd.argoproj.io/refresh=hard", "--overwrite")
        seconds = wait_until(lambda: all(gslb.request("/orders-probe/x", leg=l).status_code == 200 for l in LEGS),
                             timeout=300, interval=2, what="probe route on all legs")
        limit_hdr = gslb.request("/orders-probe/x").headers.get("RateLimit-Limit")
        after = kong_pods()
        record("gitops_change", {"seconds_from_push": round(time.monotonic() - t0, 1),
                                 "wait_seconds": round(seconds, 1), "ratelimit_limit_header": limit_hdr,
                                 "pods_before": before, "pods_after": after})
        assert after == before, "a Kong pod restarted or was replaced"
        assert limit_hdr == "7"
    finally:
        values.write_text(original)
        git("add", str(values))
        git("commit", "-m", "test(10): remove the probe route")
        git("push")


@two_legs
@pytest.mark.slow
def test_11_drain_leg_traffic_continues_and_user_limit_exact(gslb, record):
    from test_04_07_rate_limits import reset_user_counters
    drained = LEGS[-1]
    gslb_control(drained, "drain")
    try:
        legs_seen = {gslb.request("/orders/1").json()["leg"] for _ in range(4 * len(LEGS))}
        assert drained not in legs_seen
        assert legs_seen == set(LEGS) - {drained}

        reset_user_counters("users-limited")
        codes = [gslb.request("/users/limited/x", who="normaluser").status_code for _ in range(11)]
        record("drain", {"drained": drained, "legs_serving": sorted(legs_seen), "user_limit_codes": codes})
        assert codes == [200] * 10 + [429], "per-user limit not exact while a leg is drained"
    finally:
        gslb_control(drained, "ready")


def test_12_new_kong_pod_serves_full_config(gslb, tokens, record):
    leg = LEGS[0]
    deploy = f"kong-{leg}-gateway"
    old = set(oc("get", "pods", "-n", leg, "-l", f"app.kubernetes.io/instance=kong-{leg}",
                 "-o", "jsonpath={.items[*].metadata.name}").split())
    victim = next(p for p in sorted(old) if p.startswith(deploy))
    oc("delete", "pod", victim, "-n", leg, "--wait=false")
    t0 = time.monotonic()

    def new_ready_pod():
        for line in oc("get", "pods", "-n", leg, "-l", f"app.kubernetes.io/instance=kong-{leg}", "-o",
                       "jsonpath={range .items[*]}{.metadata.name} {.status.containerStatuses[0].ready}{\"\\n\"}{end}"
                       ).splitlines():
            name, ready = (line.split() + [""])[:2]
            if name.startswith(deploy) and name not in old and ready == "true":
                return name
        return None

    wait_until(lambda: new_ready_pod() is not None, timeout=300, interval=2, what="replacement pod ready")
    pod = new_ready_pod()
    ready_after = time.monotonic() - t0
    # talk to the NEW pod directly: routes, auth and limits must already be there
    pf = subprocess.Popen([KUBECTL, "port-forward", "-n", leg, f"pod/{pod}", "18000:8000"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(3)
        tok = tokens.get("normaluser")
        r_ok = requests.get("http://127.0.0.1:18000/orders/1", headers={"Authorization": f"Bearer {tok}"}, timeout=10)
        r_noauth = requests.get("http://127.0.0.1:18000/orders/1", timeout=10)
        record("scale_out", {"pod": pod, "ready_after_seconds": round(ready_after, 1),
                             "first_request": r_ok.status_code, "without_token": r_noauth.status_code,
                             "ratelimit_header": r_ok.headers.get("RateLimit-Limit")})
        assert r_ok.status_code == 200 and r_ok.json()["leg"] == leg
        assert r_noauth.status_code == 401
        assert r_ok.headers.get("RateLimit-Limit")
    finally:
        pf.terminate()
