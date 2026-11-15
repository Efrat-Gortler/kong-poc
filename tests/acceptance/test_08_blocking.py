"""8. Blocking, for the mechanism currently deployed (blocking.mode in kong-global).

A block = WHO (subject: user | system | token | everyone) + WHERE (one route, or all routes).
For each of the 7 valid combinations: block via the API -> seconds until EVERY leg returns 403
for the target; a control request (same caller elsewhere, or another caller) stays 200;
unblock -> seconds until 200 again. Everyone on all routes is rejected by the API (400).

Run once per mechanism (tests/acceptance/run-blocking-comparison.sh switches the mode through Git
and runs this file twice). Results go to tests/results/.

Target and control requests use /orders-perf (route orders-perf: same plugin chain as /orders,
limits high enough that polling every 0.25 s on both legs never meets a rate limit).
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field

import pytest

from conftest import LEGS, blocking_mode, jwt_claims, wait_until

ROUTE = "orders-perf"          # the "one route" of the route-specific cases
TARGET = "/orders-perf/1"
ELSEWHERE = "/orders/1"        # route "orders": not covered by a one-route block


@dataclass
class Caller:
    """Who sends a request: a named user/client (cached token) or one fixed token."""
    who: str | None = None
    token: str | None = None

    def kw(self) -> dict:
        return {"token": self.token} if self.token else {"who": self.who}


@dataclass
class Case:
    id: str
    subject_type: str
    route: str | None
    target: Caller
    control: Caller
    control_path: str
    subject_id: str | None = None          # None + token case: the target token's jti
    extra_blocked: list = field(default_factory=list)   # (caller, path) also blocked (all-routes cases)


def all_legs(gslb, caller: Caller, path: str, expected: int) -> bool:
    return all(gslb.request(path, leg=leg, **caller.kw()).status_code == expected for leg in LEGS)


@pytest.fixture(scope="module")
def mode():
    m = blocking_mode()
    if m == "off":
        pytest.skip("blocking.mode is off")
    return m


def cases(tokens) -> list[Case]:
    leaked = tokens.get("normaluser", fresh=True)       # each token case blocks ONE token of normaluser
    replayed = tokens.get("normaluser", fresh=True)
    return [
        Case("user@*", "user", None, Caller("666efratg"), Caller("normaluser"), TARGET,
             subject_id="666efratg@corp.local", extra_blocked=[(Caller("666efratg"), ELSEWHERE)]),
        Case("user@route", "user", ROUTE, Caller("777danag"), Caller("777danag"), ELSEWHERE,
             subject_id="777danag@corp.local"),
        Case("system@*", "system", None, Caller("reports-service"), Caller("billing-service"), TARGET,
             subject_id="reports-service", extra_blocked=[(Caller("reports-service"), ELSEWHERE)]),
        Case("system@route", "system", ROUTE, Caller("billing-service"), Caller("billing-service"), ELSEWHERE,
             subject_id="billing-service"),
        # the same user with another token is not affected
        Case("token@*", "token", None, Caller(token=leaked), Caller("normaluser"), TARGET,
             extra_blocked=[(Caller(token=leaked), ELSEWHERE)]),
        Case("token@route", "token", ROUTE, Caller(token=replayed), Caller(token=replayed), ELSEWHERE),
        Case("everyone@route", "everyone", ROUTE, Caller("normaluser"), Caller("normaluser"), ELSEWHERE),
    ]


CASE_IDS = ["user@*", "user@route", "system@*", "system@route", "token@*", "token@route", "everyone@route"]


@pytest.mark.parametrize("case_id", CASE_IDS)
def test_block_and_unblock_propagation(gslb, tokens, blocking, record, mode, case_id):
    case = next(c for c in cases(tokens) if c.id == case_id)
    enforced = 403 if mode in ("lua", "opa", "both-observe") else 200
    subject_id = case.subject_id
    if case.subject_type == "token":
        subject_id = jwt_claims(case.target.token)["jti"]
    assert all_legs(gslb, case.target, TARGET, 200), "target not reachable before the test"
    assert all_legs(gslb, case.control, case.control_path, 200), "control not reachable before the test"

    block = blocking.create(case.subject_type, subject_id, case.route, reason=f"acceptance test {case.id}")
    assert block["rule"].startswith(f"{case.subject_type}:")
    try:
        t_block = wait_until(lambda: all_legs(gslb, case.target, TARGET, enforced), timeout=60, interval=0.25,
                             what=f"{case.id} block on all legs")
        for caller, path in case.extra_blocked:
            assert all_legs(gslb, caller, path, enforced), f"{case.id}: not blocked on {path}"
        # targeted: the control request is not affected
        assert all_legs(gslb, case.control, case.control_path, 200), f"{case.id} hit the control request"
    finally:
        blocking.delete(block["id"])
    t_unblock = wait_until(lambda: all_legs(gslb, case.target, TARGET, 200), timeout=60, interval=0.25,
                           what=f"{case.id} unblock on all legs")
    record("propagation", {"mode": mode, "case": case.id, "rule": block["rule"],
                           "block_seconds": round(t_block, 2), "unblock_seconds": round(t_unblock, 2), "legs": LEGS})


def test_everyone_on_all_routes_is_rejected(blocking):
    r = blocking.post_raw(blocking.body("everyone"))
    assert r.status_code == 400, r.text
    assert "route" in r.json()["errors"]


@pytest.mark.parametrize("body,field", [
    ({"subject": {"type": "group", "id": "x"}, "reason": "r"}, "subject.type"),
    ({"subject": {"type": "user"}, "reason": "r"}, "subject.id"),
    ({"subject": {"type": "everyone", "id": "x"}, "route": ROUTE, "reason": "r"}, "subject.id"),
    ({"subject": {"type": "user", "id": "a@corp.local"}, "route": "no-such-route", "reason": "r"}, "route"),
    ({"subject": {"type": "user", "id": "a@corp.local"}}, "reason"),
], ids=["unknown-type", "missing-id", "id-for-everyone", "unknown-route", "missing-reason"])
def test_invalid_blocks_get_a_clear_400(blocking, body, field):
    r = blocking.post_raw(body)
    assert r.status_code == 400, r.text
    assert field in r.json()["errors"], r.text


def test_duplicate_block_is_409(blocking):
    b = blocking.create("user", "dup-test@corp.local", ROUTE)
    try:
        r = blocking.post_raw(blocking.body("user", "dup-test@corp.local", ROUTE))
        assert r.status_code == 409, r.text
        assert b["id"] in r.json()["detail"]
    finally:
        blocking.delete(b["id"])


def test_list_has_the_request_shape(blocking):
    b = blocking.create("token", "list-shape-test-jti", ROUTE, ttl=60)
    try:
        listed = next(x for x in blocking.list() if x["id"] == b["id"])
        assert listed["subject"] == {"type": "token", "id": "list-shape-test-jti"}
        assert listed["route"] == ROUTE
        assert listed["rule"] == f"token:list-shape-test-jti@{ROUTE}"
        assert listed["active"] is True and listed["expiresAt"]
    finally:
        blocking.delete(b["id"])


def test_expiring_block_lifts_itself(gslb, blocking, record, mode):
    ttl = 15
    normal = Caller("normaluser")
    blocking.create("user", "normaluser@corp.local", ttl=ttl)
    wait_until(lambda: all_legs(gslb, normal, TARGET, 403), timeout=60, interval=0.25, what="block")
    start = time.monotonic()
    wait_until(lambda: all_legs(gslb, normal, TARGET, 200), timeout=ttl + 60, interval=0.5, what="expiry")
    record("expiry", {"mode": mode, "ttl_seconds": ttl, "lifted_after_seconds": round(time.monotonic() - start, 2)})


def test_blocked_response_is_generic(gslb, blocking, mode):
    caller = Caller("666efratg")
    b = blocking.create("user", "666efratg@corp.local", reason="secret internal reason")
    try:
        wait_until(lambda: all_legs(gslb, caller, TARGET, 403), timeout=60, interval=0.25)
        r = gslb.request(TARGET, who="666efratg")
        assert "secret internal reason" not in r.text
        assert "666efratg" not in r.text
        assert b["id"] not in r.text
    finally:
        blocking.delete(b["id"])


def test_blocked_request_does_not_consume_quota(gslb, blocking, mode):
    from test_04_07_rate_limits import reset_user_counters
    caller = Caller("777danag")
    reset_user_counters("users-limited")
    b = blocking.create("user", "777danag@corp.local")
    try:
        # poll on another route: until the block reaches every leg the polls get 200 and would use
        # this route's quota (a user block covers all routes)
        wait_until(lambda: all_legs(gslb, caller, TARGET, 403), timeout=60, interval=0.25)
        for _ in range(15):
            assert gslb.request("/users/limited/x", who="777danag").status_code == 403
    finally:
        blocking.delete(b["id"])
    # wait for the unblock on another route, so this route's counter stays untouched
    wait_until(lambda: all_legs(gslb, caller, TARGET, 200), timeout=60, interval=0.25)
    # 15+ blocked requests consumed nothing: the full quota of 10/minute is still there
    codes = [gslb.request("/users/limited/x", who="777danag").status_code for _ in range(10)]
    assert codes == [200] * 10, codes
    assert gslb.request("/users/limited/x", who="777danag").status_code == 429
