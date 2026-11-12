# Kong Enterprise POC — option C (Git + KIC + blocking service)

Small-scale proof of concept for replacing the nginx in `flow-client` with **Kong Enterprise** on OpenShift:
DB-less Kong gateways managed by the **Kong Ingress Controller (KIC)** from Git, plus a separate **blocking
service** (C#, Swagger) that blocks users, system tokens and routes on every leg within seconds.

Background and decisions: `kong-gateway-context-en.md` and `kong-design-email.docx` (project folder).

## What it proves

| # | Capability | Where |
|---|---|---|
| 1 | Routing through a GSLB (round robin) to every leg | `charts/gslb-sim`, `charts/kong-route-lib` |
| 2–3 | JWT auth (signature, expiry, issuer, audience), no Kong Consumer per user | `charts/kong-global` (openid-connect, `credential_claim: caller_id`) |
| 4 | Route-wide limit **per leg** | `rate-limiting`, own Redis DB per leg |
| 5–7 | Per-user limit **shared across legs**, system tokens, header spoofing | `rate-limiting-advanced`, `identifier: credential`, explicit `namespace` |
| 8–9 | 4 block kinds, propagation time, behaviour when dependencies fail | `services/blocking-service`, `kong-plugins/blocklist`, `opa/policy` |
| 10 | Config change from Git with **zero pod restarts** | `argocd/`, `scripts/check-restarts.sh` |
| 11–12 | Leg drain, scale-out with full config | `scripts/drain-leg.sh` |
| 13 | Latency: no blocking vs Lua vs OPA | `tests/load/latency.js` |

## Layout

```
environments/<leg>.yaml   per-leg identity (ingress class, Redis DBs ...) - drives the ApplicationSets
charts/
  kong-values/            values for the official kong/ingress chart (one release per leg)
  kong-global/            per leg: GatewayClass, Gateway, global plugins, Redis alias, NetworkPolicies
  kong-route-lib/         library: `kongRoutes:` -> HTTPRoute + rate-limit KongPlugins
  mock-service/           echo backend used as orders / reports / users (declares its own routes)
  redis/ idp/ blocking-service/ opa/ gslb-sim/
kong-plugins/blocklist/   custom Lua plugin + busted tests
opa/policy/               Rego policy + opa tests
services/blocking-service C# (.NET 10) API, EF Core + PostgreSQL, Swagger, xUnit tests
argocd/                   root app, AppProject, ApplicationSets
scripts/                  bootstrap, secrets, Konnect, tokens, blocking CLI, drain, restart check, add-leg
tests/acceptance          pytest, all through the GSLB;  tests/load: k6
docs/                     RUNBOOK, ARCHITECTURE, TEST-REPORT, OPEN-QUESTIONS
```

Every per-leg chart has `values-<leg>.yaml`. **Adding a leg:** `scripts/add-leg.sh leg3`, commit, push,
`scripts/bootstrap.sh` (namespace, Secrets, Konnect control plane). Nothing else lists the legs except
`charts/gslb-sim/values.yaml`, which the script updates.

## Platforms

`cluster/platform.yaml` switches every chart between **`kubernetes`** (the laptop: k3d in WSL2) and
**`openshift`** (OpenShift Local or the infra team's cluster). Moving to OpenShift = change that value, set
`appsDomain` in `cluster/values-openshift.yaml`, push, run `scripts/bootstrap.sh`. Differences are listed in
[docs/RUNBOOK.md](docs/RUNBOOK.md#two-ways-to-run-it).

## Run it

See [docs/RUNBOOK.md](docs/RUNBOOK.md). Short version on OpenShift Local:

```bash
scripts/crc-setup.sh small && oc login -u kubeadmin https://api.crc.testing:6443
export KONNECT_TOKEN=... GITHUB_TOKEN=...      # never written to files
scripts/bootstrap.sh                           # then commit + push the Konnect IDs it writes
pip install -r tests/acceptance/requirements.txt && pytest tests/acceptance -v
```

## Topology (POC)

Two legs (`leg1`, `leg2`) in one cluster, each treated as a separate cluster: own KIC + gateways + mocks + OPA,
own ingress class, GatewayClass controller name and Konnect control plane. Shared: one Redis (`gw-shared`),
Keycloak simulating ADFS (`idp`), the blocking service (`blocking`), the GSLB simulator (`gslb-sim`), ArgoCD.

## Versions (pinned)

| Component | Version | Note |
|---|---|---|
| Kong Gateway Enterprise | `kong/kong-gateway:3.14.0.16` | 3.14 = LTS, supported to 2029-04. Patch tag to verify in Phase 3 |
| Kong Ingress Controller | `3.5.14` | latest 3.5.x |
| Chart `kong/ingress` | `0.24.0` | depends on `kong/kong` 3.2.0 |
| Gateway API CRDs | OpenShift: managed by the platform; Kubernetes: `v1.6.2` standard, via ArgoCD | |
| Keycloak | `26.0.7` | dev mode, realm import (OpenShift path) |
| k3d / k3s | `v5.8.3` / `v1.35.10-k3s1` | laptop path |
| Argo CD | `v3.5.7` core | laptop path |
| OPA | `1.4.2-static` | |
| Redis | `7.4.2` | counters only, no persistence |
| PostgreSQL | `16.6` | blocking service |
| HAProxy | `3.0.5` | GSLB simulator |
| .NET | 10 (LTS) | `sdk:10.0` / `aspnet:10.0` |

## License

Kong Konnect **trial** (EU region), linked per leg to a Konnect control plane of type *Kong Ingress Controller*;
KIC fetches the Enterprise license from it. Gateways stay DB-less and all config still comes from Git — Konnect
only mirrors it (read-only).

- **Trial start: 2026-11-11 (control planes `poc-leg1`, `poc-leg2`, EU) — expires around 2026-12-11.**
- Konnect receives configuration metadata from KIC and needs egress from the cluster to `*.konghq.com:443`
  — worth a line to the security team.

## Deviations from the session prompt / design (and why)

| Prompt / design said | Done instead | Why |
|---|---|---|
| 3 legs | **2 legs** (`leg1`, `leg2`), extensible with `scripts/add-leg.sh` | user's decision |
| Install Gateway API CRDs (`v1.6.2` per Kong docs) | use the CRDs OpenShift ships | OpenShift 4.19+ manages them and blocks external management |
| `rate-limiting-advanced identifier: consumer` (email) | `identifier: credential` + OIDC `credential_claim` | no Consumer per user (known correction) |
| Per-user rule after route-wide | per-user plugin runs **first** (Enterprise dynamic ordering) | a noisy caller should not burn the route budget of everybody; toggle `kongRouteDefaults.userLimitFirst` |
| KIC admission webhook | **off** | chart-generated certificate drifts under ArgoCD; production: cert-manager |
| Per-leg cluster-scoped names | prefixed with the leg (`leg1-openid-connect`, GatewayClass `kong-leg1`) | both legs share one cluster; in production plain names work |
| EF Core migrations | `EnsureCreated()` | POC; no migration tooling in the image |
| Images built locally | OpenShift `BuildConfig` from GitHub | the workstation needs no .NET SDK / registry |
| Swagger write auth via OAuth flow | paste a bearer token (`scripts/get-token.sh opsadmin`) | Keycloak's issuer is pinned to the in-cluster URL (so Kong and workstation tokens agree) |
| Prometheus ServiceMonitor | metrics exposed, scraped manually | CRC disables cluster monitoring by default (saves ~4 GiB) |
| OpenShift cluster | laptop: k3d (plain Kubernetes) in WSL2 | the only workstation has 8 GB RAM and Windows Home (no Hyper-V); charts stay OpenShift-ready via `global.platform` |
| Keycloak | laptop: `mini` token issuer (same realm files, same URLs) | Keycloak needs ~600 MB of a 5 GB budget |
| 2 legs always on | laptop: leg2 parked in `environments/standby/`, brought up for multi-leg tests | memory |
| Kong HPA 2–5 | laptop: one Kong pod per leg, no HPA | memory; test 12 replaces a pod instead of scaling out |
| OpenShift GitOps operator | laptop: upstream Argo CD core (no UI) in namespace `openshift-gitops` | memory; same Application manifests on both platforms |
| GCP VM: HAProxy publishes 80/443/6443 of the CRC VM | HAProxy only `<host IP>:6443 -> 127.0.0.1:6443`; the crc daemon publishes 80/443 | CRC's default *user* network mode already binds 80/443 on all interfaces (HAProxy failed with "Address already in use") and 6443 on 127.0.0.1 |
| GCP VM: OpenShift starts again by itself | `loginctl enable-linger` + user unit `crc-autostart.service` (`crc start` at boot, `crc stop` at shutdown) | the crc daemon is a systemd user service: without lingering it died with the last SSH session and the CRC VM lost its network; nothing ran `crc start` after the nightly stop |
| `oc login -u kubeadmin` on the VM | `KUBECONFIG=~/.kube/config:~/.crc/machines/crc/kubeconfig` in `~/.bashrc` (CRC's certificate-based admin) | after the nightly stop `crc stop` removed the crc-admin context and `crc start` at boot failed to re-add it (OAuth not ready); that context's token expires after 24 h anyway |
| Kong CRDs from the KIC repo (`config/crd?ref=v3.5.14`) via Argo CD | vendored file `cluster/crds/kong/kong-crds-v3.5.14.yaml` | the repo-server's fetch of the whole KIC repo with all tags timed out (1m40s) |
| `configPatches` read the Secret keys `password` / `api-key` | read JSON-quoted copies `password-json` / `api-key-json` (added by `scripts/create-secrets.sh`) | KIC inserts the value as JSON; a bare string fails with "could not parse KongPlugin ... invalid state detected" |
| `opa run --watch /policy` | plus `--ignore=.*` | a ConfigMap volume also holds the files in hidden `..data` dirs: OPA loaded the policy three times ("multiple default rules") |
| Argo CD core with laptop memory caps | controller 1536Mi, repo-server 1Gi limits | the application controller was OOMKilled at 448Mi with two legs |
| BuildConfig with source secret `github-source` | no source secret by default (public repo) | the build pod waited for a Secret that is only created with `GITHUB_TOKEN` |
| Kong default upstream retries (5) | `konghq.com/retries: "1"` per Service (`kongTimeouts.retries`) | Kong also retries after a read timeout: a slow backend got the request 6 times and the caller waited 6 x 10 s (the OpenShift router cut it at 30 s) |
| Per-user limit: sliding window everywhere | the test-only routes `users-limited`, `users-limited-2` use `window_type: fixed` (`userLimitWindow`) | a sliding window also counts the previous minute, which Kong caches locally: the tests' Redis reset could not clear it. Real routes stay sliding |
