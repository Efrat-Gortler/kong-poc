"""Shared fixtures for the acceptance tests.

Run from a workstation that is logged in to the cluster (`oc whoami` works):
    pip install -r tests/acceptance/requirements.txt
    pytest tests/acceptance -v                      # safe tests
    pytest tests/acceptance -v -m destructive       # scales things down and back
    ALLOW_GIT_PUSH=1 pytest tests/acceptance -v -m gitops

Every request goes through the GSLB simulator. A test may pin a request to one
leg with the x-gslb-leg header (still through the GSLB, just not round robin).
Measurements are written to tests/results/<test>.json for docs/TEST-REPORT.md.
"""
from __future__ import annotations

import base64
import json
import os
import subprocess
import time
import urllib3
from dataclasses import dataclass, field
from pathlib import Path

import pytest
import requests

urllib3.disable_warnings()

REPO = Path(__file__).resolve().parents[2]
RESULTS = REPO / "tests" / "results"
DOMAIN = os.environ.get("APPS_DOMAIN", "apps-crc.testing")
GSLB_URL = os.environ.get("GSLB_URL", f"https://gslb-gslb-sim.{DOMAIN}")
GSLB_CONTROL_URL = os.environ.get("GSLB_CONTROL_URL", f"https://gslb-control-gslb-sim.{DOMAIN}")
KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", f"https://keycloak-idp.{DOMAIN}")
BLOCKING_URL = os.environ.get("BLOCKING_URL", f"https://blocking-blocking.{DOMAIN}")
LEGS = sorted(p.stem for p in (REPO / "environments").glob("*.yaml"))
USERS = {"666efratg", "777danag", "normaluser", "opsadmin"}


# ---------------------------------------------------------------- helpers
def oc(*args: str, check: bool = True, input: str | None = None) -> str:
    r = subprocess.run(["oc", *args], capture_output=True, text=True, input=input)
    if check and r.returncode != 0:
        raise RuntimeError(f"oc {' '.join(args)} failed: {r.stderr.strip()}")
    return r.stdout


def secret(ns: str, name: str, key: str) -> str:
    raw = oc("get", "secret", name, "-n", ns, "-o", f"jsonpath={{.data.{key}}}")
    return base64.b64decode(raw).decode()


def wait_until(predicate, timeout: float = 60, interval: float = 0.5, what: str = "condition") -> float:
    """Polls until predicate() is truthy. Returns the seconds it took."""
    start = time.monotonic()
    while True:
        if predicate():
            return time.monotonic() - start
        if time.monotonic() - start > timeout:
            raise AssertionError(f"timed out after {timeout}s waiting for {what}")
        time.sleep(interval)


def jwt_claims(token: str) -> dict:
    payload = token.split(".")[1]
    return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))


@dataclass
class Tokens:
    _cache: dict = field(default_factory=dict)

    def _fetch(self, who: str) -> dict:
        realm = "rogue" if who == "rogue-service" else "corp"
        url = f"{KEYCLOAK_URL}/realms/{realm}/protocol/openid-connect/token"
        if who in USERS:
            data = {"grant_type": "password", "client_id": "poc-cli", "username": who,
                    "password": secret("idp", "idp-test-credentials", "KC_TEST_USER_PASSWORD"), "scope": "openid"}
        else:
            data = {"grant_type": "client_credentials", "client_id": who,
                    "client_secret": secret("idp", "idp-test-credentials", "KC_SYSTEM_CLIENT_SECRET")}
        r = requests.post(url, data=data, verify=False, timeout=10)
        r.raise_for_status()
        return r.json()

    def get(self, who: str, fresh: bool = False) -> str:
        """Access token for a user or a client. fresh=True always returns a NEW token."""
        if fresh:
            return self._fetch(who)["access_token"]
        tok, exp = self._cache.get(who, (None, 0))
        if not tok or exp - time.time() < 30:
            tok = self._fetch(who)["access_token"]
            self._cache[who] = (tok, jwt_claims(tok).get("exp", 0))
        return tok


class Gslb:
    def __init__(self, tokens: Tokens):
        self.tokens = tokens
        self.s = requests.Session()
        self.s.verify = False

    def request(self, path: str, who: str | None = "normaluser", leg: str | None = None,
                method: str = "GET", token: str | None = None, headers: dict | None = None,
                timeout: float = 15) -> requests.Response:
        h = dict(headers or {})
        if token is None and who:
            token = self.tokens.get(who)
        if token:
            h["Authorization"] = f"Bearer {token}"
        if leg:
            h["x-gslb-leg"] = leg
        # new connection per request -> real round robin in HAProxy
        h.setdefault("Connection", "close")
        return self.s.request(method, f"{GSLB_URL}{path}", headers=h, timeout=timeout)

    def status_on_all_legs(self, path: str, who: str | None = "normaluser", **kw) -> dict[str, int]:
        return {leg: self.request(path, who=who, leg=leg, **kw).status_code for leg in LEGS}


class Blocking:
    def __init__(self, tokens: Tokens):
        self.tokens = tokens

    def _h(self):
        return {"Authorization": f"Bearer {self.tokens.get('opsadmin')}"}

    def create(self, kind: str, caller_id: str | None = None, route: str | None = None,
               reason: str = "acceptance test", ttl: int | None = None) -> dict:
        body = {"kind": kind, "reason": reason}
        if caller_id:
            body["callerId"] = caller_id
        if route:
            body["route"] = route
        if ttl:
            body["ttlSeconds"] = ttl
        r = requests.post(f"{BLOCKING_URL}/api/blocks", json=body, headers=self._h(), verify=False, timeout=10)
        assert r.status_code == 201, r.text
        return r.json()

    def delete(self, block_id: str) -> None:
        r = requests.delete(f"{BLOCKING_URL}/api/blocks/{block_id}", headers=self._h(), verify=False, timeout=10)
        assert r.status_code in (204, 404), r.text

    def clear(self) -> None:
        r = requests.get(f"{BLOCKING_URL}/api/blocks", headers=self._h(), verify=False, timeout=10)
        r.raise_for_status()
        for b in r.json():
            self.delete(b["id"])


def gslb_control(leg: str, action: str) -> dict:
    r = requests.post(f"{GSLB_CONTROL_URL}/legs/{leg}/{action}", verify=False, timeout=10)
    r.raise_for_status()
    return r.json()


def redis_cli(*args: str) -> str:
    pod = oc("get", "pod", "-n", "gw-shared", "-l", "app.kubernetes.io/name=redis",
             "-o", "jsonpath={.items[0].metadata.name}")
    return oc("exec", "-n", "gw-shared", pod, "--", "sh", "-c",
              'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ' + " ".join(args))


def redis_flush_matching(db: int, pattern: str) -> int:
    """Deletes counter keys so a test starts from zero (rate-limit windows)."""
    keys = [k for k in redis_cli("-n", str(db), "--scan", "--pattern", f"'{pattern}'").split() if k]
    for i in range(0, len(keys), 200):
        redis_cli("-n", str(db), "del", *[f"'{k}'" for k in keys[i:i + 200]])
    return len(keys)


def blocking_mode() -> str:
    """lua | opa | both-observe | off - read from leg1's KongClusterPlugins."""
    names = oc("get", "kongclusterplugins", "-o", "jsonpath={.items[*].metadata.name}").split()
    lua, opa = f"{LEGS[0]}-blocklist" in names, f"{LEGS[0]}-opa" in names
    if lua and opa:
        return "both-observe"
    return "lua" if lua else "opa" if opa else "off"


# ---------------------------------------------------------------- fixtures
@pytest.fixture(scope="session")
def tokens() -> Tokens:
    return Tokens()


@pytest.fixture(scope="session")
def gslb(tokens) -> Gslb:
    return Gslb(tokens)


@pytest.fixture(scope="session")
def blocking(tokens) -> Blocking:
    b = Blocking(tokens)
    b.clear()
    yield b
    b.clear()


@pytest.fixture(scope="session", autouse=True)
def all_legs_in_rotation():
    for leg in LEGS:
        gslb_control(leg, "ready")
    yield
    for leg in LEGS:
        gslb_control(leg, "ready")


@pytest.fixture
def record(request):
    """record(key, value) -> tests/results/<test name>.json"""
    data: dict = {}

    def _record(key, value):
        data[key] = value

    yield _record
    if data:
        RESULTS.mkdir(parents=True, exist_ok=True)
        name = request.node.name.replace("/", "_")
        (RESULTS / f"{name}.json").write_text(json.dumps(data, indent=2, default=str))


def pytest_configure(config):
    config.addinivalue_line("markers", "destructive: scales shared components down and back up")
    config.addinivalue_line("markers", "gitops: pushes a temporary commit to the repo (needs ALLOW_GIT_PUSH=1)")
    config.addinivalue_line("markers", "slow: waits for rate-limit windows")
