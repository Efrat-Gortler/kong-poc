# Open questions — to verify before production

Each item: what the POC assumed, and what must be checked.

## Identity (real ADFS)
- [ ] **Issuer URL format** of ADFS (`https://<adfs>/adfs` vs with a trailing path) — Kong's `issuer` and
      `issuers_allowed` must match the `iss` claim exactly.
- [ ] **Audience**: what `aud` ADFS puts in tokens for the gateway (relying-party identifier). POC: `api://kong-gateway`.
- [ ] **`upn` format** (`user@domain` vs `DOMAIN\user`), and whether case is stable — blocks and counters are exact-match.
- [ ] **System tokens**: which claim identifies the application (`appid`, `client_id`, …). POC simulates a
      unified claim `caller_id` (= `upn` for users, client id for system tokens): ask ADFS for this claim rule.
- [ ] **Tokens without `caller_id` are accepted** (TEST-REPORT test 3, finding 1): decide to reject them in the gateway or require the claim from ADFS.
- [ ] **Client-sent identity headers** (`caller_id`, `x-credential-identifier`) reach the upstream (finding 2): strip them globally, or make every backend trust `x-caller-id` only.
- [ ] Wrong `aud`: openid-connect answers **403** `insufficient_scope` (audience_required is an authorization check), not 401. Confirm clients treat both as "token rejected".
- [ ] JWKS rotation: Kong caches keys; confirm rollover handling with ADFS's signing-certificate rollover.

## Rate limiting / Redis
- [ ] **One shared Redis in production** means a cross-datacenter write on every request with a per-user limit
      (`sync_rate: 0`) and a dependency between the legs. Measure added latency; alternatives: Redis per leg with the
      per-user threshold set to `limit / (legs-1)`, or active-active Redis (Redis Enterprise). Not active-passive.
- [x] Behaviour when Redis is unreachable: both plugins let traffic through, no limit enforced (TEST-REPORT test 9). Decide whether that is acceptable.
- [ ] Sliding windows keep the previous minute in a local cache: a Redis reset does not clear a caller's quota at once (finding 4).
- [ ] Whether the organisation has active-active replicated Redis.
- [ ] Execution order of the two rate-limit plugins (same priority 910) — the POC forces per-user first with
      Enterprise dynamic ordering; confirm this is wanted and supported in the chosen version.

## To confirm on the running POC (Phase 3–8)
- [x] `kong.client.get_credential().id` equals the `caller_id` value when openid-connect uses `credential_claim`
      (test 8 "user" passes in Lua mode).
- [x] Redis key format of `rate-limiting-advanced` contains the namespace in clear text (`<window start>:60:<route>-user`).
- [ ] `opa run --watch` together with a configured bundle (policy hot-reload) — not verified yet; note `--ignore=.*` is now needed for the ConfigMap volume.
- [x] Exact Kong Gateway patch tag: `3.14.0.16` runs; `3.14.0.17` is available (upgrade = one line in Git).
- [x] Konnect KIC hostname for the EU region: `eu.kic.api.konghq.com` works (license + config sync).
- [x] NuGet package versions for .NET 10: the in-cluster build restores and runs the unit tests (one compile fix: ambiguous `JsonOptions`).

## Not covered on the laptop (k3d) — re-test on the infra cluster
- [x] Routes, edge TLS on the router (verified on OKD).
- [x] The restricted-v2 SCC: all POC pods run under it on OKD (Argo CD core needs nonroot-v2).
- [x] Gateway API CRDs managed by OpenShift (`v1.4.1` on OKD 4.22) work with KIC 3.5.14.
- [x] BuildConfig in-cluster build.
- [ ] OpenShift GitOps operator (the laptop runs upstream Argo CD core).
- [ ] NetworkPolicy namespace labels specific to OpenShift (router, DNS, monitoring).
- [x] Keycloak as the token issuer (still a simulation of ADFS).
- [ ] Kong with 2+ pods per leg and HPA; latency numbers (laptop numbers are only comparative).

## Not covered on the GCP VM (OKD via OpenShift Local)
- [ ] OKD is the community build of OpenShift: same APIs (Routes, SCCs, BuildConfig, managed Gateway API CRDs), but not the Red Hat product build.
- [ ] OpenShift GitOps operator (OKD has no redhat-operators catalog; upstream Argo CD core is used, with the nonroot-v2 SCC for its service accounts).

## Kong / OpenShift
- [ ] OpenShift version of the production clusters ≥ 4.19 (Gateway API CRDs managed by the platform) and which
      Gateway API version they ship; KIC 3.5 compatibility with it.
- [ ] SCC: the POC runs Kong with `containerSecurityContext.enabled: false` under `restricted-v2`. Confirm no extra SCC.
- [ ] Upstream retries: Kong's default (5) also retries read timeouts; the POC uses 1 per Service. Agree on a value per backend.
- [ ] Mirroring `kong/kong-gateway`, `kong/kubernetes-ingress-controller` and the chart to the internal registry.
- [ ] Admission webhook with cert-manager (off in the POC).
- [ ] Gateway pod labels for the egress NetworkPolicy (off until verified).
- [ ] The plugin compatibility table for the installed Kong version (`openid-connect`, `rate-limiting-advanced`,
      `opa`, dynamic ordering, `configure` handler used by the Lua plugin).
- [ ] Gateway sizing: Kong's Konnect example requests 1 CPU / 2 GiB per gateway pod; the POC uses less.

## License
- [ ] License terms for multiple production environments (3 clusters) — Konnect trial only covers the POC (trial started 2026-11-11, ends around 2026-12-11).
- [ ] Production license source: `KongLicense` resource from a `license.json` (no Konnect) vs Konnect.
- [ ] Konnect receives configuration metadata — security review if Konnect stays.

## GSLB / traffic
- [ ] How the real GSLB spreads one user's requests across legs: DNS TTL, long-lived (keep-alive) connections.
- [ ] Health check the GSLB should use (Kong `/status/ready` on the status port).

## Blocking service
- [ ] Where it runs in production (one leg? all three with a shared DB?) — today it is central, a single point
      for *changes* (not for enforcement: gateways keep the last list).
- [ ] Operator authentication: who gets the `blocker` role in ADFS.
- [ ] Retention of the audit table.
