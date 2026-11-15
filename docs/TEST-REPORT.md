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
| 8 | Blocking: 7 WHO × WHERE combinations × 2 mechanisms; API validation (400 / 409); expiry; generic body; no quota used | pass (Lua 18/18, OPA 18/18; re-run 2026-11-15 after the block-model redesign) | see table below |
| 9 | Blocking service down / Redis down | pass / documented | blocks kept in both mechanisms, new blocks impossible (503); Redis down: both rate-limit plugins let traffic through |
| 10 | Git change live, zero restarts | pass | new route + threshold live on both legs **4.8 s** after `git push` (hard refresh); same Kong pods, no restarts |
| 11 | Drain a leg: traffic continues, per-user limit exact | pass | leg2 drained → only leg1 serves; per-user limit exact: 10 × 200, then 429 |
| 12 | New pod serves full config | pass | replacement gateway pod ready after **15.2 s**; first request 200, no token 401, limits present |
| 13 | Latency off / Lua / OPA | done | see table below |

## Lua vs OPA

Block model (since 2026-11-15): a block = WHO (`user` | `system` | `token` by `jti` | `everyone`) + WHERE
(one route, or all routes); see ARCHITECTURE "Block model". Propagation: one run per combination and
mechanism, measured until **both** legs return 403 (block) / 200 (unblock), polling every 0.25 s; bounded by
the polling intervals (Lua: 5 s per gateway pod, OPA: bundle every 2–4 s). Latency: k6, 50 req/s for 60 s
(3,000 requests per run), route `/orders-perf` (same plugin chain as `/orders`), two system tokens.

| Block → all legs 403 / unblock → all legs 200 (s) | Lua `blocklist` | OPA |
|---|---|---|
| user, all routes | 3.7 / 4.8 | 2.2 / 3.5 |
| user, one route | 4.2 / 5.0 | 2.5 / 4.1 |
| system, all routes | 4.2 / 5.0 | 2.2 / 2.5 |
| system, one route | 4.5 / 4.8 | 3.0 / 2.2 |
| token (`jti`), all routes | 4.8 / 4.8 | 3.3 / 2.2 |
| token (`jti`), one route | 4.5 / 4.8 | 2.5 / 2.2 |
| everyone, one route | 4.5 / 5.1 | 3.4 / 3.1 |
| **range** | **3.7–4.8 / 4.8–5.1** | **2.2–3.4 / 2.2–4.1** |
| everyone, all routes | rejected by the API (400) | same |
| Expiring block (TTL 15 s) lifted after (s, from when the block was seen on all legs) | 15.2 | 13.1 (block itself took ~2 s to appear) |
| Blocking service down | existing blocks kept on both legs, other users 200; new block → 503 | same |
| Dependency down (OPA) | n/a | **500 for every request on that leg** (fail closed, immediate); other leg unaffected |
| Moving parts / operations | plugin code in a ConfigMap; restart the gateway pods to load new code | OPA Deployment per leg + Rego; policy hot-reload not verified yet |

| Latency through GSLB + router (ms) | p50 | p95 | p99 |
|---|---|---|---|
| off (no blocking plugin) | 6.9 | 11.1 | 15.5 |
| Lua (3 runs; the plugin now also decodes the JWT payload) | 6.6–6.8 | 9.3–15.4 | 11.7–29.3 (one noisy run; the other two 11.7 / 12.8) |
| OPA | 8.3 | 11.7 | 14.9 |

Added latency at the median: **Lua ≈ 0, OPA +1.4 ms**. Tails (p95/p99) vary more between runs than between mechanisms on this single-node cluster; the medians are
stable across runs (2026-11-11: off 7.2, Lua 7.1, OPA 8.9 ms).

## Redis down (test 9)

| Plugin | Observed | Seconds |
|---|---|---|
| `rate-limiting` (`fault_tolerant: true`) | 200, request proxied, no limit enforced | 0.03 |
| `rate-limiting-advanced` | 200, request proxied, no limit enforced | 0.02 |

With Redis down **no** rate limit is enforced (route-wide or per user) and requests are not slowed down.

## Findings

1. **Tokens without `caller_id` are accepted** (test 3). They pass openid-connect, are not identifiable
   upstream, cannot be blocked per caller (only by token `jti`, route or everyone-on-route since the block-model redesign), and share one per-user counter keyed on the client IP (the
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
6. **Konnect rejected every KIC config upload** (`no plugin-schema for 'blocklist'`): the custom plugin schema must be
   uploaded to each control plane (`scripts/konnect-setup.sh` now does it; needs `KONNECT_TOKEN`). Gateways and license were not affected.
7. First-run fixes needed on OpenShift (all in Git, listed in README "Deviations"): vendored Kong CRDs,
   JSON-quoted secret values for `configPatches`, `opa --ignore=.*` for ConfigMap volumes, Argo CD memory,
   a .NET 10 compile fix.

## Recommendation

**Use the Lua `blocklist` plugin**, keep OPA only as an option if authorization logic grows beyond lookups.

- **Latency:** the Lua plugin adds no measurable latency at the median, also with the new block model (JWT
  payload decode + at most 5 table lookups); OPA adds about 1.5–2 ms at the median on every request, for an
  HTTP call that answers a simple key lookup. Tails are too noisy here to separate the two.
- **Availability:** OPA turns every request on a leg into a 500 when the leg's OPA is down. The Lua plugin has
  no extra runtime dependency; both mechanisms keep the last list when the blocking service is down.
- **Propagation:** OPA was faster here (2.2–3.4 s vs 3.7–4.8 s for all 7 combinations) only because it polls more often. The Lua poll
  interval is a setting (`blocking.pollIntervalSeconds`); 2 s gives a similar result at negligible cost
  (one conditional GET per pod every 2 s).
- **Operations:** the Lua plugin is custom code that must be re-tested on every Kong upgrade and needs a pod
  restart to load a new version. OPA's Rego hot-reloads and is a standard product, at the cost of one more
  Deployment per leg (and per cluster in production) to run, monitor and size.

OPA becomes the better choice if blocking turns into richer policy (attributes, time windows, combinations
of conditions) where a policy language pays off.

Before production: decide on findings 1 and 2, re-measure latency on the real clusters with 2+ gateway pods
per leg, and confirm the open items in `docs/OPEN-QUESTIONS.md`.
