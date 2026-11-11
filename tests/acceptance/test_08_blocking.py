"""8. Blocking, for the mechanism currently deployed (blocking.mode in kong-global):
block via the API -> seconds until EVERY leg returns 403; unblock -> until 200;
an expiring block lifts itself.

Run once per mechanism (tests/acceptance/run-blocking-comparison.sh switches the
mode through Git and runs this file twice). Results go to tests/results/.
"""
import time

import pytest

from conftest import LEGS, blocking_mode, wait_until

CASES = [
    # kind,           caller_id,              route,            request as (who, path),          control request
    ("user",          "666efratg@corp.local", None,             ("666efratg", "/orders/1"),      ("normaluser", "/orders/1")),
    ("system_token",  "reports-service",      None,             ("reports-service", "/reports/1"), ("billing-service", "/reports/1")),
    ("route",         None,                   "reports-limited", ("normaluser", "/reports/limited/z"), ("normaluser", "/reports/1")),
    ("user_on_route", "777danag@corp.local",  "orders-create",  ("777danag", "POST /orders"),    ("777danag", "/orders/1")),
]


def call(gslb, who, path, leg):
    method, _, p = path.rpartition(" ")
    return gslb.request(p, who=who, leg=leg, method=method or "GET").status_code


def all_legs(gslb, who, path, expected):
    return all(call(gslb, who, path, leg) == expected for leg in LEGS)


@pytest.fixture(scope="module")
def mode():
    m = blocking_mode()
    if m == "off":
        pytest.skip("blocking.mode is off")
    return m


@pytest.mark.parametrize("kind,caller,route,target,control", CASES, ids=[c[0] for c in CASES])
def test_block_and_unblock_propagation(gslb, blocking, record, mode, kind, caller, route, target, control):
    enforced = 403 if mode in ("lua", "opa", "both-observe") else 200
    if route == "reports-limited":
        # test 4 exhausts this route's per-leg limit (20/min); start from zero
        from test_04_07_rate_limits import reset_route_counters
        reset_route_counters()
    assert all_legs(gslb, *target, 200), "target not reachable before the test"

    block = blocking.create(kind, caller_id=caller, route=route)
    t_block = wait_until(lambda: all_legs(gslb, *target, enforced), timeout=60, interval=0.25,
                         what=f"{kind} block on all legs")
    # targeted: the control request is not affected
    assert all_legs(gslb, *control, 200), "block hit an unrelated caller/route"

    blocking.delete(block["id"])
    t_unblock = wait_until(lambda: all_legs(gslb, *target, 200), timeout=60, interval=0.25,
                           what=f"{kind} unblock on all legs")
    record("propagation", {"mode": mode, "kind": kind, "block_seconds": round(t_block, 2),
                           "unblock_seconds": round(t_unblock, 2), "legs": LEGS})


def test_expiring_block_lifts_itself(gslb, blocking, record, mode):
    ttl = 15
    blocking.create("user", caller_id="normaluser@corp.local", ttl=ttl)
    wait_until(lambda: all_legs(gslb, "normaluser", "/orders/1", 403), timeout=60, interval=0.25, what="block")
    start = time.monotonic()
    wait_until(lambda: all_legs(gslb, "normaluser", "/orders/1", 200), timeout=ttl + 60, interval=0.5, what="expiry")
    record("expiry", {"mode": mode, "ttl_seconds": ttl, "lifted_after_seconds": round(time.monotonic() - start, 2)})


def test_blocked_response_is_generic(gslb, blocking, mode):
    b = blocking.create("user", caller_id="666efratg@corp.local", reason="secret internal reason")
    try:
        wait_until(lambda: all_legs(gslb, "666efratg", "/orders/1", 403), timeout=60, interval=0.25)
        r = gslb.request("/orders/1", who="666efratg")
        assert "secret internal reason" not in r.text
        assert "666efratg" not in r.text
    finally:
        blocking.delete(b["id"])


def test_blocked_request_does_not_consume_quota(gslb, blocking, mode):
    from test_04_07_rate_limits import reset_user_counters
    reset_user_counters("users-limited")
    b = blocking.create("user", caller_id="777danag@corp.local")
    try:
        # poll on another route: until the block reaches every leg the polls get 200 and would use
        # this route's quota (a user block covers all routes)
        wait_until(lambda: all_legs(gslb, "777danag", "/orders/1", 403), timeout=60, interval=0.25)
        for _ in range(15):
            assert gslb.request("/users/limited/x", who="777danag").status_code == 403
    finally:
        blocking.delete(b["id"])
    # wait for the unblock on another route, so this route's counter stays untouched
    wait_until(lambda: all_legs(gslb, "777danag", "/orders/1", 200), timeout=60, interval=0.25)
    # 15+ blocked requests consumed nothing: the full quota of 10/minute is still there
    codes = [gslb.request("/users/limited/x", who="777danag").status_code for _ in range(10)]
    assert codes == [200] * 10, codes
    assert gslb.request("/users/limited/x", who="777danag").status_code == 429
