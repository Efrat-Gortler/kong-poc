"""2. Authentication and 3. missing caller_id claim."""
import base64
import json
import time

import pytest

from conftest import LEGS, jwt_claims


def tamper_signature(token: str) -> str:
    h, p, s = token.split(".")
    flipped = ("A" if s[0] != "A" else "B") + s[1:]
    return ".".join([h, p, flipped])


def forge_claims(token: str, **changes) -> str:
    h, p, s = token.split(".")
    claims = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
    claims.update(changes)
    p2 = base64.urlsafe_b64encode(json.dumps(claims).encode()).rstrip(b"=").decode()
    return ".".join([h, p2, s])


def test_no_token_401(gslb):
    assert gslb.status_on_all_legs("/orders/1", who=None) == {l: 401 for l in LEGS}


def test_garbage_token_401(gslb):
    assert gslb.request("/orders/1", token="not-a-jwt").status_code == 401


def test_bad_signature_401(gslb, tokens):
    assert gslb.request("/orders/1", token=tamper_signature(tokens.get("normaluser"))).status_code == 401


def test_forged_caller_id_401(gslb, tokens):
    # changing a claim breaks the signature
    forged = forge_claims(tokens.get("normaluser"), caller_id="opsadmin@corp.local")
    assert gslb.request("/orders/1", token=forged).status_code == 401


def test_wrong_issuer_401(gslb, tokens):
    tok = tokens.get("rogue-service")
    assert jwt_claims(tok)["iss"].endswith("/realms/rogue")
    assert gslb.request("/orders/1", token=tok).status_code == 401


def test_wrong_audience_401(gslb, tokens):
    tok = tokens.get("other-app")
    assert "api://kong-gateway" not in json.dumps(jwt_claims(tok).get("aud"))
    assert gslb.request("/orders/1", token=tok).status_code == 401


@pytest.mark.slow
def test_expired_token_401(gslb, tokens):
    tok = tokens.get("short-lived", fresh=True)
    assert gslb.request("/orders/1", token=tok).status_code == 200
    time.sleep(max(0, jwt_claims(tok)["exp"] - time.time()) + 3)
    assert gslb.request("/orders/1", token=tok).status_code == 401


def test_valid_user_token_200_and_caller_forwarded(gslb):
    r = gslb.request("/orders/1", who="normaluser")
    assert r.status_code == 200
    assert r.json()["headers"].get("x-caller-id") == "normaluser@corp.local"


def test_valid_system_token_200(gslb):
    r = gslb.request("/reports/1", who="reports-service")
    assert r.status_code == 200
    assert r.json()["headers"].get("x-caller-id") == "reports-service"


def test_03_missing_caller_id_claim_documented(gslb, tokens, record):
    """The token is valid but has no caller_id (credential_claim). Record what Kong does."""
    tok = tokens.get("legacy-service")
    assert "caller_id" not in jwt_claims(tok)
    statuses = {}
    for path in ("/orders/1", "/users/limited/x"):
        r = gslb.request(path, token=tok)
        statuses[path] = {"status": r.status_code, "body": r.text[:200],
                          "ratelimit_headers": {k: v for k, v in r.headers.items() if "ratelimit" in k.lower()}}
    record("missing_caller_id", statuses)
    # Whatever the behaviour is, it must not be a server error.
    assert all(s["status"] < 500 for s in statuses.values()), statuses
