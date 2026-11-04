# Open questions — to verify before production

Each item: what the POC assumed, and what must be checked.

## Identity (real ADFS)
- [ ] **Issuer URL format** of ADFS (`https://<adfs>/adfs` vs with a trailing path) — Kong's `issuer` and
      `issuers_allowed` must match the `iss` claim exactly.
- [ ] **Audience**: what `aud` ADFS puts in tokens for the gateway (relying-party identifier). POC: `api://kong-gateway`.
- [ ] **`upn` format** (`user@domain` vs `DOMAIN\user`), and whether case is stable — blocks and counters are exact-match.
- [ ] **System tokens**: which claim identifies the application (`appid`, `client_id`, …). POC simulates a
      unified claim `caller_id` (= `upn` for users, client id for system tokens): ask ADFS for this claim rule.
- [ ] Behaviour of Kong when `caller_id` is missing — see TEST-REPORT test 3.
- [ ] JWKS rotation: Kong caches keys; confirm rollover handling with ADFS's signing-certificate rollover.

## Rate limiting / Redis
- [ ] **One shared Redis in production** means a cross-datacenter write on every request with a per-user limit
      (`sync_rate: 0`) and a dependency between the legs. Measure added latency; alternatives: Redis per leg with the
      per-user threshold set to `limit / (legs-1)`, or active-active Redis (Redis Enterprise). Not active-passive.
- [ ] Behaviour when Redis is unreachable for each plugin — see TEST-REPORT test 9.
- [ ] Whether the organisation has active-active replicated Redis.
- [ ] Execution order of the two rate-limit plugins (same priority 910) — the POC forces per-user first with
      Enterprise dynamic ordering; confirm this is wanted and supported in the chosen version.

## Kong / OpenShift
- [ ] OpenShift version of the production clusters ≥ 4.19 (Gateway API CRDs managed by the platform) and which
      Gateway API version they ship; KIC 3.5 compatibility with it.
- [ ] SCC: the POC runs Kong with `containerSecurityContext.enabled: false` under `restricted-v2`. Confirm no extra SCC.
- [ ] Mirroring `kong/kong-gateway`, `kong/kubernetes-ingress-controller` and the chart to the internal registry.
- [ ] Admission webhook with cert-manager (off in the POC).
- [ ] Gateway pod labels for the egress NetworkPolicy (off until verified).
- [ ] The plugin compatibility table for the installed Kong version (`openid-connect`, `rate-limiting-advanced`,
      `opa`, dynamic ordering, `configure` handler used by the Lua plugin).
- [ ] Gateway sizing: Kong's Konnect example requests 1 CPU / 2 GiB per gateway pod; the POC uses less.

## License
- [ ] License terms for multiple production environments (3 clusters) — Konnect trial only covers the POC.
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
