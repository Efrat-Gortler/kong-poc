# Test report

Environment: OpenShift Local 2.63 with the OKD preset (OKD `4.22.0-okd-scos.6`, Kubernetes 1.35) on a GCP
n2-standard-8 VM (CRC VM: 7 vCPU / 26 GiB), profile `small`, 2 legs in one single-node cluster,
Kong Gateway Enterprise `3.14.0.16` (license from Konnect, EU), KIC `3.5.14`, Gateway API CRDs `v1.4.1`
(shipped by OKD), Argo CD `v3.5.7` core. Date: 2026-11-11.

All requests go through the GSLB simulator and the OpenShift router, so latencies include two extra
HAProxy hops. Both legs share one node: numbers are **comparative**, not capacity figures. Raw results:
`tests/results/*.json` (not committed).

| # | Test | Result | Notes |
|---|---|---|---|
| 1 | Routing, round robin over all legs | pass | distribution 4 / 4 over leg1 / leg2; unknown path 404; POST exception route; Service read timeout → 504 |
| 2 | Auth: none / garbage / bad signature / forged claim / wrong issuer / expired → 401; wrong audience → 403; user & system → 200 | pass | wrong `aud` gives **403** `insufficient_scope`, not 401 (`audience_required` is an authorization check in openid-connect) |
| 3 | Token without `caller_id` | documented | **accepted (200)**. No `x-caller-id` upstream; the per-user limit falls back to the client IP (behind the router/GSLB: one shared counter for all such callers); cannot be blocked by caller. See "Findings" |
| 4 | Route-wide limit per leg | pass | 20/min: leg1 → 429 after 20, leg2 still 200 |
| 5 | Per-user limit shared across legs; separate per user, per route; shared across a user's tokens | pass | 10/min: after 10 requests spread over both legs, 429 on both |
| 6 | System token own counter | pass | |
| 7 | Header spoofing | pass (identity) | `x-caller-id` = token's `caller_id`; counter unchanged. But client-sent `caller_id` and `x-credential-identifier` headers **reach the upstream unchanged** — see "Findings" |
| 8 | Blocking × 4 kinds × 2 mechanisms; expiry; generic body; no quota used | pass (Lua and OPA) | see table below |
| 9 | Blocking service down / Redis down | pass / documented | blocks kept in both mechanisms, new blocks impossible (503); Redis down: both rate-limit plugins let traffic through |
| 10 | Git change live, zero restarts | pass | new route + threshold live on both legs **4.8 s** after `git push` (hard refresh); same Kong pods, no restarts |
| 11 | Drain a leg: traffic continues, per-user limit exact | pass | leg2 drained → only leg1 serves; per-user limit exact: 10 × 200, then 429 |
| 12 | New pod serves full config | pass | replacement gateway pod ready after **15.2 s**; first request 200, no token 401, limits present |
| 13 | Latency off / Lua / OPA | done | see table below |

## Lua vs OPA

Propagation is one run per kind and mechanism; it is bounded by the polling intervals
(Lua: 5 s per gateway pod, OPA: bundle every 2–4 s). Latency: k6, 50 req/s for 60 s (3,000 requests per mode),
route `/orders-perf` (same plugin chain as `/orders`), two system tokens.

| | Lua `blocklist` | OPA |
|---|---|---|
| Block → all legs 403 (s): user / system_token / route / user_on_route | 5.2 / 4.9 / 3.8 / 4.9 | 2.5 / 3.3 / 2.8 / 2.8 |
| Unblock → all legs 200 (s) | 4.6 / 4.9 / 4.9 / 4.9 | 3.0 / 2.5 / 2.7 / 3.3 |
| Expiring block (TTL 15 s) lifted after (s) | 15.1 | 15.2 |
| Blocking service down | existing blocks kept on both legs, other users 200; new block → 503 | same |
| Dependency down (OPA) | n/a | **500 for every request on that leg** (fail closed, immediate); other leg unaffected |
| p50 / p95 / p99 (ms), off = 7.2 / 11.6 / 16.1 | 7.1 / 10.0 / 13.7 | 8.9 / 13.6 / 19.8 |
| Added latency vs off (p50 / p95 / p99) | ≈ 0 (within noise) | +1.7 / +2.0 / +3.7 ms |
| Moving parts / operations | plugin code in a ConfigMap; restart the gateway pods to load new code | OPA Deployment per leg + Rego; policy hot-reloads |

## Redis down (test 9)

| Plugin | Observed | Seconds |
|---|---|---|
| `rate-limiting` (`fault_tolerant: true`) | 200, request proxied, no limit enforced | 0.03 |
| `rate-limiting-advanced` | 200, request proxied, no limit enforced | 0.02 |

With Redis down **no** rate limit is enforced (route-wide or per user) and requests are not slowed down.

## Findings

1. **Tokens without `caller_id` are accepted** (test 3). They pass openid-connect, are not identifiable
   upstream, cannot be blocked per caller, and share one per-user counter keyed on the client IP (the
   router/GSLB address). Options: reject them in the gateway (e.g. the blocklist plugin / OPA policy returns
   401 when there is no credential), or require ADFS to always issue the claim. Recommended: reject.
2. **Identity headers from the client reach the upstream** (test 7): `caller_id` and `x-credential-identifier`
   sent by the client are forwarded unchanged; only `x-caller-id` is overwritten by the gateway. Backends must
   trust `x-caller-id` only, or the gateway should strip these headers (request-transformer, global).
3. **Kong retries timed-out requests 5 times by default.** A slow backend received the same request 6 times
   and the caller waited 6 × read timeout. The POC sets `konghq.com/retries: "1"` per Service.
4. **Sliding windows cache the previous minute locally.** Resetting a per-user counter in Redis does not
   clear the previous window's count (operations, e.g. "unblock this user's quota now", must take this into
   account). Production routes keep the sliding window; the test routes use fixed windows.
5. **OPA is a hard runtime dependency** of every request on its leg (500 when it is down); the Lua
   plugin has none (it keeps the last list in shared memory).
6. First-run fixes needed on OpenShift (all in Git, listed in README "Deviations"): vendored Kong CRDs,
   JSON-quoted secret values for `configPatches`, `opa --ignore=.*` for ConfigMap volumes, Argo CD memory,
   a .NET 10 compile fix.

## Recommendation

**Use the Lua `blocklist` plugin**, keep OPA only as an option if authorization logic grows beyond lookups.

- **Latency:** the Lua plugin adds no measurable latency (in-memory lookup); OPA adds about 2 ms at p50/p95
  and 4 ms at p99 per request, on every request, for an HTTP call that answers a simple list lookup.
- **Availability:** OPA turns every request on a leg into a 500 when the leg's OPA is down. The Lua plugin has
  no extra runtime dependency; both mechanisms keep the last list when the blocking service is down.
- **Propagation:** OPA was faster here (≈ 3 s vs ≈ 5 s) only because it polls more often. The Lua poll
  interval is a setting (`blocking.pollIntervalSeconds`); 2 s gives a similar result at negligible cost
  (one conditional GET per pod every 2 s).
- **Operations:** the Lua plugin is custom code that must be re-tested on every Kong upgrade and needs a pod
  restart to load a new version. OPA's Rego hot-reloads and is a standard product, at the cost of one more
  Deployment per leg (and per cluster in production) to run, monitor and size.

OPA becomes the better choice if blocking turns into richer policy (attributes, time windows, combinations
of conditions) where a policy language pays off.

Before production: decide on findings 1 and 2, re-measure latency on the real clusters with 2+ gateway pods
per leg, and confirm the open items in `docs/OPEN-QUESTIONS.md`.
