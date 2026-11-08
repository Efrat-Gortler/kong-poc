"""1. Routing: each mock route answers; responses come from every leg (round robin)."""
from collections import Counter

import pytest

from conftest import LEGS, two_legs


@pytest.mark.parametrize("path,service", [
    ("/orders/123", "orders"),
    ("/reports/daily", "reports"),
    ("/users/me", "users"),
])
def test_route_reaches_backend(gslb, path, service):
    r = gslb.request(path)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["service"] == service
    assert body["path"] == path          # strip-path off: backend sees the full path
    assert body["leg"] in LEGS


def test_post_exception_route(gslb):
    # orders-create (POST /orders) is a separate route with its own thresholds
    r = gslb.request("/orders", method="POST")
    assert r.status_code == 200
    assert r.json()["method"] == "POST"
    assert r.headers.get("RateLimit-Limit") or r.headers.get("X-RateLimit-Limit-Minute")


def test_unknown_path_is_404(gslb):
    assert gslb.request("/nope").status_code == 404


@two_legs
def test_round_robin_hits_every_leg(gslb, record):
    seen = Counter(gslb.request("/orders/rr").json()["leg"] for _ in range(4 * len(LEGS)))
    record("distribution", dict(seen))
    assert set(seen) == set(LEGS), f"not all legs answered: {dict(seen)}"


def test_upstream_timeout_from_service_annotation(gslb):
    # mock Service has konghq.com/read-timeout=10000
    assert gslb.request("/orders/slow?ms=200").status_code == 200
    r = gslb.request("/orders/slow?ms=12000", timeout=30)
    assert r.status_code == 504
