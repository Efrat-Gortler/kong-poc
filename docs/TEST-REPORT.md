# Test report

_Not run yet._ Filled in from `tests/results/*.json` after Phase 10.

Environment: OpenShift Local `<version>` (OpenShift `<version>`), profile `<small|full>`, 2 legs in one cluster,
Kong Gateway `<version>`, KIC `3.5.14`. Date: `<date>`.

| # | Test | Result | Notes |
|---|---|---|---|
| 1 | Routing, round robin over all legs | | distribution: |
| 2 | Auth: none / garbage / bad signature / forged claim / wrong issuer / wrong audience / expired → 401; user & system → 200 | | |
| 3 | Token without `caller_id` | documented | observed: |
| 4 | Route-wide limit per leg | | |
| 5 | Per-user limit shared across legs; separate per user, per route; shared across a user's tokens | | |
| 6 | System token own counter | | |
| 7 | Header spoofing | | upstream headers: |
| 8 | Blocking × 4 kinds × 2 mechanisms; expiry; generic body; no quota used | | see table below |
| 9 | Blocking service down / Redis down | | |
| 10 | Git change live, zero restarts | | seconds from push: |
| 11 | Drain a leg: traffic continues, per-user limit exact | | |
| 12 | New pod serves full config | | ready after: |
| 13 | Latency off / Lua / OPA | | see table below |

## Lua vs OPA

| | Lua `blocklist` | OPA |
|---|---|---|
| Block → all legs 403 (s): user / system_token / route / user_on_route | | |
| Unblock → all legs 200 (s) | | |
| Expiring block lifted after TTL + (s) | | |
| Blocking service down | | |
| Dependency down (OPA) | n/a | |
| p50 / p95 / p99 (ms), off = | | |
| Moving parts / operations | plugin code in a ConfigMap; restart to load new code | OPA Deployment per leg + Rego; policy hot-reloads |

## Redis down (test 9)

| Plugin | Observed | Seconds |
|---|---|---|
| `rate-limiting` (`fault_tolerant: true`) | | |
| `rate-limiting-advanced` | | |

## Recommendation

_To write after the numbers are in._
