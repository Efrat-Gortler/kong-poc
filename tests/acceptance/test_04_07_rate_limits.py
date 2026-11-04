"""4. route-wide limit is per leg, 5. per-user limit shared across legs,
6. system token has its own counter, 7. header spoofing does not change the counter."""
import time

import pytest
import yaml

from conftest import LEGS, REPO, redis_flush_matching

ENV = {leg: yaml.safe_load((REPO / "environments" / f"{leg}.yaml").read_text()) for leg in LEGS}
USER_DB = ENV[LEGS[0]]["global"]["redis"]["userLimitDatabase"]


def reset_route_counters():
    for leg in LEGS:
        redis_flush_matching(ENV[leg]["global"]["redis"]["routeLimitDatabase"], "ratelimit:*")


def reset_user_counters(route: str):
    redis_flush_matching(USER_DB, f"*{route}-user*")


def wait_for_fresh_minute(margin: int = 15):
    """rate-limiting uses fixed minute windows: start well inside one."""
    s = time.time() % 60
    if s > 60 - margin:
        time.sleep(60 - s + 1)


@pytest.mark.slow
def test_04_route_limit_is_per_leg(gslb, record):
    limit = 20   # reports-limited: routeLimitPerMinute
    reset_route_counters()
    wait_for_fresh_minute(margin=20)
    first, other = LEGS[0], LEGS[1]
    codes = [gslb.request("/reports/limited/a", who="normaluser", leg=first).status_code for _ in range(limit)]
    assert codes == [200] * limit, codes
    over = gslb.request("/reports/limited/a", who="normaluser", leg=first)
    other_leg = gslb.request("/reports/limited/a", who="normaluser", leg=other)
    record("per_leg", {"limit": limit, "first_leg_after_limit": over.status_code,
                       "other_leg": other_leg.status_code})
    assert over.status_code == 429
    assert other_leg.status_code == 200, "route-wide limit leaked into the other leg"


def test_05_user_limit_shared_across_legs(gslb, tokens, record):
    limit = 10   # users-limited: userLimitPerMinute
    reset_user_counters("users-limited")
    codes = [gslb.request("/users/limited/x", who="777danag", leg=LEGS[i % len(LEGS)]).status_code
             for i in range(limit)]
    assert codes == [200] * limit, codes
    over = {leg: gslb.request("/users/limited/x", who="777danag", leg=leg).status_code for leg in LEGS}
    record("shared_counter", {"limit": limit, "after_limit_per_leg": over})
    assert set(over.values()) == {429}, over


def test_05_other_user_has_own_counter(gslb):
    reset_user_counters("users-limited")
    for _ in range(10):
        gslb.request("/users/limited/x", who="777danag")
    assert gslb.request("/users/limited/x", who="777danag").status_code == 429
    assert gslb.request("/users/limited/x", who="normaluser").status_code == 200


def test_05_same_user_two_tokens_share_counter(gslb, tokens):
    reset_user_counters("users-limited")
    t1, t2 = tokens.get("666efratg", fresh=True), tokens.get("666efratg", fresh=True)
    assert t1 != t2
    for i in range(10):
        assert gslb.request("/users/limited/x", token=t1 if i % 2 else t2).status_code == 200
    assert gslb.request("/users/limited/x", token=t1).status_code == 429
    assert gslb.request("/users/limited/x", token=t2).status_code == 429


def test_05_same_user_two_routes_separate_counters(gslb):
    reset_user_counters("users-limited")
    reset_user_counters("users-limited-2")
    for _ in range(10):
        gslb.request("/users/limited/x", who="normaluser")
    assert gslb.request("/users/limited/x", who="normaluser").status_code == 429
    assert gslb.request("/users/limited2/x", who="normaluser").status_code == 200


def test_06_system_token_has_own_counter(gslb):
    reset_user_counters("users-limited")
    for _ in range(10):
        gslb.request("/users/limited/x", who="normaluser")
    assert gslb.request("/users/limited/x", who="normaluser").status_code == 429
    codes = [gslb.request("/users/limited/x", who="reports-service").status_code for _ in range(10)]
    assert codes == [200] * 10
    assert gslb.request("/users/limited/x", who="reports-service").status_code == 429
    assert gslb.request("/users/limited/x", who="billing-service").status_code == 200


def test_07_spoofed_headers_do_not_change_identity_or_counter(gslb, record):
    reset_user_counters("users-limited")
    spoof = {"x-caller-id": "someone-else", "caller_id": "someone-else",
             "x-consumer-username": "someone-else", "x-credential-identifier": "someone-else"}
    r = gslb.request("/users/limited/x", who="normaluser", headers=spoof)
    assert r.status_code == 200
    upstream = r.json()["headers"]
    record("upstream_identity_headers", {k: upstream.get(k) for k in spoof})
    assert upstream.get("x-caller-id") == "normaluser@corp.local", "client-sent x-caller-id reached the backend"
    for _ in range(9):
        gslb.request("/users/limited/x", who="normaluser", headers=spoof)
    # the 11th request is limited although every request claimed a different identity
    assert gslb.request("/users/limited/x", who="normaluser", headers=spoof).status_code == 429
