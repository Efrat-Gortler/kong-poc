# Option A — Kong Manager, self-hosted (design)

Status: **B0–B2 built** (namespaces, Secrets, Postgres, control plane) and free mode verified on 3.14 (2026-11-17). Built next to option C in the same cluster; option C
(`leg1`, `leg2`, `kong-global`, blocking service, OPA and their Argo CD apps) is not touched.

## Goal

Everything that changes day to day — services, routes, rate limits, blocks — is managed **in Kong Manager**
(stored in Postgres), with **no extra service** (no blocking service, no OPA) and **no route configuration in
Git**. Git / Helm / Argo CD only install the infrastructure: Postgres, the control plane, the data planes,
Redis, backends and the GSLB simulator.

**No Enterprise license is available for now.** Option A is first built in **free mode** (Kong Gateway
Enterprise image without a license) to get hands-on experience with Kong Manager. The design below keeps the
licensed parts ready (see "Free mode vs licensed").

## 1. License

| Question | Finding |
|---|---|
| Can the Konnect trial license be used by a self-hosted control plane? | **No.** Konnect provisions licenses to the organisation for Konnect-connected gateways; Kong states the Konnect license key cannot be accessed or retrieved directly. KIC's license agent fetches it for Konnect-linked gateways only (option C). Using it elsewhere is not intended by the trial terms. |
| What is needed instead | A license JSON for self-managed Kong Gateway Enterprise: a trial from Kong (sales / support portal, "license.json"), or the organisation's existing license. |
| How it will be applied | `POST /licenses` on the control plane's Admin API (payload read from an OpenShift Secret by a script, never printed). The control plane then **sends the license to every data plane** — the only method that reaches data planes automatically. (`KONG_LICENSE_DATA` / `license.json` would have to be on every node before it starts.) |
| Free mode in 3.14 | **Verified on the running control plane (3.14.0.16, no license): the Admin API is writable** — see "Free mode, verified" below. Background: free mode was **deprecated in 3.10** ("will be removed in a future 3.x version; running without a license will then behave like an expired license"). With an expired license the Admin API and Kong Manager are **read-only** (documented for 3.15+). Whether 3.14.0.x still runs a *writable* free mode is **not stated in the docs** → it is the first thing the build verifies (step B1). Fallback if 3.14 is read-only without a license: the same design on the 3.10 LTS Enterprise image (free mode still present), recorded as a deviation. |

### Free mode, verified (3.14.0.16, no license, 2026-11-17)

Admin API of the control plane (`GET /` → `edition: enterprise`, `license: none`, `/licenses` empty):

| Request | Result |
|---|---|
| `POST /services`, `POST /services/{s}/routes` | 201 |
| `rate-limiting` on a route, `policy: redis`, `database: 4` | 201 |
| `rate-limiting` with `redis.host: {vault://env/kong-route-rl-redis-host}` | 201 (accepted; resolution on the data planes is verified in B4) |
| `PATCH /plugins/{id}` (edit) | 200 |
| `request-termination` on a route | 201 |
| `jwt` (`claims_to_verify: [exp]`, `key_claim_name: iss`) | 201 |
| `request-termination` with `ordering.before.access: [rate-limiting]` | **400 `ordering requires a license to be used`** |
| `openid-connect`, `rate-limiting-advanced` | **400 `'…' is an enterprise only plugin`** |
| Kong Manager (port 8002) | 200, served |

So the 3.10 LTS fallback is not needed. Consequence of "no dynamic ordering" in free mode: `request-termination`
(priority 2) runs **after** `rate-limiting` (910), so requests to a blocked route still count against that route's
limit. For everyone-on-route blocks this is harmless (the route is closed); for the licensed Consumer blocks the
ordering is set once the license is applied.

### Free mode vs licensed

| Capability | Free mode (now) | Licensed (later) |
|---|---|---|
| Kong Manager: create/edit services, routes, plugins, consumers | ✔ (verified) | ✔ |
| Kong Manager **login, RBAC**, workspaces | ✘ — **no login: anyone who reaches the Route is admin** | ✔ basic-auth (POC) → OIDC to the IdP |
| Audit log (who changed what) | ✘ | ✔ `audit_log = on` |
| Dynamic plugin ordering | ✘ (400 `ordering requires a license`) | ✔ |
| JWT validation | `jwt` plugin (OSS): signature (RS256, IdP public key on a Consumer named after the issuer) + `exp`. **No `aud` check, no JWKS rotation, no per-user identity** | `openid-connect`: JWKS, `iss`/`aud`/`exp`, `credential_claim: caller_id`, consumer mapping |
| Route-wide limit per leg | `rate-limiting` (OSS), `policy: redis`, per-leg Redis (section 3) | same |
| Per-user limit across legs | ✘ (the jwt plugin's consumer is the issuer, not the user) | `rate-limiting-advanced`, `identifier: credential`, Redis DB 3 in `gw-shared` |
| Block everyone on route Y | ✔ `request-termination` on the route (runs after rate limiting: no dynamic ordering) | ✔, ordered before rate limiting |
| Block user / system on all routes or route Y | ✘ (no per-user consumer) | ✔ Consumer per caller + `request-termination` (section 5) |
| Block one token (`jti`) | ✘ | custom plugin (section 5) |
| Secrets in plugin config (`{vault://env/...}`) | ✔ accepted by the CP (DP resolution: B4) | ✔ |
| decK dump (backup) | ✔ | ✔ |

Added once the license arrives (in this order): apply the license (`/licenses`) → `enforce_rbac`,
`admin_gui_auth: basic-auth` + super-admin password from a Secret → `audit_log` → `openid-connect`
(replaces `jwt`) with consumer mapping → `rate-limiting-advanced` per user → Consumer-based blocking →
`jti` plugin. Each step is a Helm values change (infrastructure) or a change in Kong Manager (configuration).

## 2. Architecture (hybrid mode)

Kubernetes namespace names must be lower case, so `kongA-*` becomes **`konga-*`**.

```
            Windows browser (POC route only)
                    │  https://kong-manager-konga-cp.<apps>   https://kong-admin-konga-cp.<apps>
                    ▼
 konga-cp      ┌──────────────────────────────┐      ┌───────────────┐
               │ control plane (role CP)      │─────▶│ Postgres 16   │
               │ Admin API 8001, Manager 8002 │      └───────────────┘
               │ cluster 8005 (mTLS, shared)  │
               └──────┬───────────────┬───────┘
          config push │               │ config push
 konga-leg1    ┌──────▼─────┐   konga-leg2 ┌──────▼─────┐
               │ DP (DB-less│             │ DP (DB-less│      gw-shared: Redis (DB 3: per-user, licensed)
               │ role DP)   │             │ role DP)   │
               │ redis-route│             │ redis-route│      idp: Keycloak (same realms as option C)
               │ orders/... │             │ orders/... │
               └──────▲─────┘             └──────▲─────┘
                      └──────── konga-gslb: GSLB simulator (round robin, drain) ──── client
```

| Component | Chart / image | Namespace | Requests (CPU / memory) |
|---|---|---|---|
| Postgres 16.6 (StatefulSet, PVC 2 Gi) | own small chart (same pattern as the blocking DB) | `konga-cp` | 50m / 128Mi |
| Control plane: `role: control_plane`, `database: postgres`, Admin API, Kong Manager, cluster listener | `kong/kong` 3.4.1 (latest chart), image `kong/kong-gateway:3.14.0.16`, `ingressController.enabled: false`, migrations as Helm hooks | `konga-cp` | 250m / 512Mi |
| Data plane ×2: `role: data_plane`, `database: off`, `cluster_control_plane: <cp>:8005` | same chart and image | `konga-leg1`, `konga-leg2` | 2 × 200m / 384Mi |
| Redis for the route limit, one per leg | `charts/redis` (reused) | `konga-leg1`, `konga-leg2` | 2 × 20m / 32Mi |
| Backends orders / reports / users | `charts/mock-service` (reused, `kongRoutes: []`) | `konga-leg1`, `konga-leg2` | 6 × 10m / 32Mi |
| GSLB simulator for the A legs | `charts/gslb-sim` (reused, own values) | `konga-gslb` | 50m / 64Mi |
| **Total** | | | **≈ 1.1 CPU / 2.0 Gi** |

The VM (CRC: 6.8 CPU / 25 Gi allocatable) has 3.3 CPU (48 %) and 11.5 Gi (46 %) requested today; with
option A ≈ 64 % CPU and 54 % memory requested. **It fits**, with room for a second DP pod per leg.

Wiring:
- **Cluster trust:** `cluster_mtls: shared` — one self-signed certificate/key, created by
  `scripts/option-a/create-secrets.sh` as Secret `kong-cluster-cert` in the CP and both DP namespaces (never in Git).
- **Postgres password:** Secret `konga-postgres`, created by the same script.
- **Argo CD:** a new AppProject `kong-poc-a` (destinations `konga-*`, `gw-shared` read-only) and
  `argocd/apps/option-a.yaml` with the A applications. Option C's project, ApplicationSets and apps stay as they are.
- **Exposure:** Routes for Kong Manager and for the Admin API (Kong Manager is a browser app that calls the
  Admin API directly), and for the A GSLB. All under `apps-crc.testing`, reachable only from the allowed IP
  range of the GCP firewall. **In free mode neither has a login** — documented risk, POC only.
- **Identity provider:** the existing Keycloak (`idp`), realms unchanged.

## 3. Route limit per leg

In hybrid mode every data plane receives the **same** plugin configuration. A `rate-limiting` plugin with
`policy: redis` pointing at one Redis/DB therefore gives **one counter for all legs**. Verified on the
running Kong 3.14: in `rate-limiting` and `rate-limiting-advanced` the fields `redis.host`, `redis.port`
and `redis.password` are `referenceable`; **`redis.database` is not** — so "DB 4 for leg 1, DB 5 for leg 2"
cannot be expressed in one plugin configuration.

| Option | How | Pros | Cons |
|---|---|---|---|
| **A. Per-leg Redis host** (recommended) | `redis.host: {vault://env/kong-route-rl-redis-host}`; each DP gets `KONG_ROUTE_RL_REDIS_HOST` pointing at its leg's Redis. Fallback without the env vault: the short name `redis-route`, which Kubernetes DNS resolves inside each DP's own namespace | Exact per-leg counter, one config in Kong Manager; matches production, where each leg (cluster) has a local Redis and avoids a cross-datacenter round trip | One Redis per leg; the env vault in free mode is to verify (fallback works anyway); the DNS-name variant is implicit |
| B. `policy: local` | counters in each DP's memory | No Redis | Per **pod**, not per leg: with N pods the leg allows N × limit; changes with scaling |
| C. Control plane per leg | Two CPs + two databases | Any per-leg config | Two Kong Managers, every change twice — defeats the purpose of option A |
| D. `limit_by: header` with a leg header | a per-leg header as the identifier | One Redis | Needs a trusted, gateway-set per-leg header; no native way to inject a per-node value without a custom plugin |

Recommendation: **A** — Redis DB 4 on each leg's own Redis (same DB number on both, so the single plugin config
works). Redis in `gw-shared` keeps only the shared per-user counters (DB 3, licensed) — nothing mixes with option C
(DBs 0–2).

## 4. Per-user limit across legs (licensed)

`rate-limiting-advanced`, `identifier: credential` (openid-connect `credential_claim: caller_id`), explicit
`namespace` per route (`a-<route>-user`), `strategy: redis`, `sync_rate: 0`, Redis in `gw-shared`, **DB 3**,
password as `{vault://env/...}`. Same as option C except the DB. Not possible in free mode.

## 5. Blocking without an extra service

| Combination | Kong-native entity (managed in Kong Manager) | Free mode |
|---|---|---|
| everyone, route Y | `request-termination` (403) on route Y | ✔ |
| user X / system X, all routes | Consumer `X` (openid-connect `consumer_claims: [caller_id]`, `consumer_by: [username]`, `consumer_optional: true` — normal callers need no Consumer) + `request-termination` scoped to Consumer X | ✘ |
| user X / system X, route Y | same Consumer + `request-termination` scoped to Consumer X **and** route Y | ✘ |
| token (`jti`), all routes / route Y | no native plugin → small custom plugin `jti-block` (config: list of `jti` values, editable as a form in Kong Manager), global or on route Y; code shipped like option C's plugin (ConfigMap, infrastructure). Alternative: IdP-side revocation + openid-connect introspection (Keycloak yes; ADFS has no introspection) | ✘ |
| everyone, all routes | a global `request-termination` — **Kong accepts it** (no validation) and would stop all traffic; prevent by RBAC/process | — |

Points to verify when licensed:
- **Order:** `request-termination` has priority 2, rate limiting 910 — so by default a blocked request **still
  consumes quota**. Use dynamic ordering (`ordering.before.access: [rate-limiting, rate-limiting-advanced]`) on
  the termination plugins. Kong ≤ 3.13 ignored consumer-scoped plugins when dynamic ordering was in use; the docs
  say this was resolved in 3.14 — to verify.
- **User vs system:** a Consumer is found by the claim value only; if an upn and a client id were equal they would
  be the same Consumer. In practice they differ (upn contains `@`); tag Consumers `user` / `system`.
- **Lost compared with option C:** expiry (no TTL on a plugin — unblock by hand), reason (use tags), duplicate
  detection, one place listing all blocks (they are spread over Consumers and plugins), the Swagger API.

Propagation: a change in Kong Manager is written to Postgres; the CP pushes the new config to every DP over the
cluster connection (target: seconds). Measured by the build (create/delete in the Admin API, poll both legs
through the GSLB until they enforce it), for routes, rate limits and `request-termination`.

## 6. Kong Manager access, audit, backup

| | Free mode (now) | Licensed |
|---|---|---|
| Login | **none** — Kong Manager and the Admin API are reachable without credentials; exposed only on the POC Routes, behind the GCP firewall's allowed IP range | `enforce_rbac: on`, `admin_gui_auth: basic-auth`, session secret and super-admin password (`KONG_PASSWORD` at bootstrap) from Secrets; later `admin_gui_auth: openid-connect` against the IdP |
| Roles | — | RBAC roles per workspace (e.g. `blocker`: consumers + request-termination only; `operator`: routes and limits) |
| Audit | Postgres only has the current state | `audit_log: on`, `audit_log_record_ttl`; `/audit/requests`, `/audit/objects` |
| Backup / history | `CronJob` running `deck gateway dump` (pinned decK) every hour into a PVC, keeping N files with timestamps; plus a nightly `pg_dump`. Optionally the dumps go to a **private backup repository** (history and diff, not the source of truth) | same |

## 7. Upgrades in DB mode

- **Migrations:** `kong migrations up` (expand: new schema, old nodes keep working) → roll out the new control plane
  → `kong migrations finish` (contract: removes what old nodes needed). The chart runs them as Helm hooks
  (`migrations.preUpgrade` / `postUpgrade`), which Argo CD runs as PreSync / PostSync hooks.
- **Order in hybrid:** control plane first, then data planes (rolling). A control plane accepts data planes of the
  same major version and the same or an **older** minor version; a newer data plane is rejected. Mixed versions are
  fine during the upgrade, not long term.
- **Rollback:** before `finish`, the old version can run again on the expanded schema. **After `finish` there is no
  downgrade path** except restoring the Postgres backup taken before `migrations up` (and the decK dump); data planes
  keep serving their last config meanwhile. Rule: `pg_dump` + `deck gateway dump` before every upgrade.
- Compared with option C: C is DB-less — upgrade = new image tag in Git, rollback = `git revert`.

## Build plan (after approval) — stops marked ⏸ need your OK

| Step | What | Cluster-wide / needs admin |
|---|---|---|
| ✔ B0 | Create namespaces `konga-cp`, `konga-leg1`, `konga-leg2`, `konga-gslb` and the AppProject `kong-poc-a` | yes (namespaces, AppProject) |
| ✔ B1 | Secrets (`scripts/option-a/create-secrets.sh`): Postgres password, cluster cert | no |
| ✔ B2 | Postgres + control plane through Argo CD (Kong Enterprise also needs `cluster_telemetry_listen` on a CP). **Verify free mode on 3.14**: `POST /services` on the Admin API succeeds. If read-only → stop and report (fallback 3.10 LTS) | no |
| B3 | Routes for Kong Manager and Admin API; open Kong Manager from Windows (hosts entries below) | no |
| B4 | Data planes + per-leg Redis + backends in `konga-leg1/2`; check both DPs connected (`/clustering/data-planes`) | no |
| B5 | GSLB simulator for the A legs in `konga-gslb` + Route | no |
| B6 | In Kong Manager (and scripted through the Admin API for repeatability): services/routes for orders/reports/users, `jwt` with the Keycloak `corp` realm key, `rate-limiting` per route (redis, per-leg host), `request-termination` on a route. Verify each on the cluster | no |
| B7 | Measure propagation (Kong Manager/Admin API change → both legs enforce) | no |
| B8 | Acceptance tests that apply to free mode (routing, round robin, JWT signature/expiry, route limit per leg, everyone-on-route block, drain, new DP pod) → `docs/TEST-REPORT-A.md` with the A-vs-C table | no |

Windows hosts entries to add (B3/B5; `scripts/windows/hosts-crc.cmd` will be updated):
`kong-manager-konga-cp.apps-crc.testing`, `kong-admin-konga-cp.apps-crc.testing`, `gslb-konga-gslb.apps-crc.testing`
→ the VM's IP.

Open items before production: license source and terms for three clusters; Kong Manager behind OIDC;
which team owns configuration changes in Kong Manager (no review step like a Git pull request).
