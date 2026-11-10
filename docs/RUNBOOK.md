# Runbook — from an empty workstation to a passing test suite

Commands in order. Each phase ends with a check; don't continue until it passes.
Secrets are only ever in environment variables or OpenShift Secrets.

## Two ways to run it

| | Laptop | OpenShift (GCP VM with OpenShift Local — current — or the infra cluster) |
|---|---|---|
| `cluster/platform.yaml` | `platform: kubernetes` | `platform: openshift` + `appsDomain` in `cluster/values-openshift.yaml` |
| Cluster | k3d (k3s 1.35) in WSL2, Docker Engine | OpenShift 4.19+ |
| Exposure | Ingress (Traefik) on `http://*.localtest.me` | Routes on `https://*.<appsDomain>` |
| GitOps | Argo CD 3.5.7 core (no UI), namespace `openshift-gitops` | OpenShift GitOps operator |
| Token issuer | `mini` (charts/idp/files/mini_issuer.py) | Keycloak |
| Blocking service image | GitHub Actions → `ghcr.io` | BuildConfig in the cluster |
| Bootstrap | `scripts/k3d/cluster.sh create` then `scripts/bootstrap.sh` | `scripts/bootstrap.sh` |

Everything else (charts, plugins, tests) is the same.

## GCP path — OpenShift Local on a Google Cloud VM (current)

`cluster/platform.yaml`: `platform: openshift`. Both legs active. Free Trial credit; the VM stops itself at 22:00.

| Where | What |
|---|---|
| Google Cloud Shell | creates and drives the VM (`scripts/gcp/*.sh`) |
| VM `kong-poc-crc` (n2-standard-8, CentOS Stream 9) | OpenShift Local 2.63, **OKD preset** (no Red Hat account; `PRESET=openshift` + pull secret for OCP), 7 vCPU / 26 GiB (user network mode: the crc daemon publishes 80/443, HAProxy adds 6443; lingering + `crc-autostart` user unit), `oc`, `helm`, `gh`, test venv |
| Your Windows browser | console and POC routes, via hosts entries (`scripts/windows/hosts-crc.cmd`) |

1. **Cloud Shell:** `git clone https://github.com/Efrat-Gortler/kong-poc.git && cd kong-poc`
   (or upload `kong-poc.bundle` and `git clone kong-poc.bundle kong-poc`).
2. **(only for `PRESET=openshift`) Pull secret:** Cloud Shell menu ⋮ → *Upload* → the Red Hat pull secret, then `mv ~/pull-secret* ~/pull-secret.txt`.
   With OKD (default) Argo CD is the upstream core install (no OpenShift GitOps operator in OKD's catalog).
3. **VM:** `ALLOW_IP=<your public IP> bash scripts/gcp/create-vm.sh` (~5 min).
4. **OpenShift Local:** `bash scripts/gcp/vm.sh setup` (30–40 min, mostly waiting).
5. **Windows hosts entries (admin, once):** run `scripts/windows/hosts-crc.cmd` that Claude generates with the VM IP.
6. **Bootstrap (on the VM):** `bash scripts/gcp/vm.sh ssh`, then in `~/kong-poc`:
   `oc login -u kubeadmin https://api.crc.testing:6443` (password: `crc console --credentials`),
   `read -rs KONNECT_TOKEN && export KONNECT_TOKEN`, `gh auth login`, `scripts/bootstrap.sh`.
7. **Tests (on the VM):** `~/.venv/bin/pytest tests/acceptance -v`.
8. **Daily:** `bash scripts/gcp/vm.sh start` in the morning (the `crc-autostart` user unit starts OpenShift, ~10 min; check `crc status`); it stops at 22:00
   by itself, or `bash scripts/gcp/vm.sh stop`.

## Laptop path — WSL2 + k3d (8 GB machine)

Memory budget: WSL is capped at 5 GB (`%USERPROFILE%\.wslconfig`). One leg ≈ 1.6 GB of pods,
the second leg ≈ +0.6 GB. Close Chrome, Steam, BlueStacks and WhatsApp before steps marked **[heavy]**.

0. **Windows (admin + reboot, once):** double-click `scripts/windows/install-wsl.cmd`, restart,
   open *Ubuntu 24.04* once and choose a Linux user name and password.
1. **Repo into WSL** (in Ubuntu; the bundle is the file Claude saved into your Windows folder):
   ```bash
   W="/mnt/c/Users/<you>/Desktop/<folder>"
   git clone -b main "$W/kong-poc.bundle" ~/kong-poc && cd ~/kong-poc
   git remote set-url origin https://github.com/Efrat-Gortler/kong-poc.git
   export POC_LOG_DIR="$W/logs"           # every script also writes its output there
   ```
2. **Tools:** `bash scripts/wsl/setup-tools.sh` (asks for the Linux password). Close and reopen Ubuntu.
3. **GitHub login (pushes from WSL):** `gh auth login` (GitHub.com → HTTPS → browser), then `gh auth setup-git`,
   then `git push origin main`. Later updates from Claude: `scripts/sync-from-claude.sh "$W/kong-poc.bundle"`.
4. **[heavy] Cluster:** `scripts/k3d/cluster.sh create` (pulls k3s, ~1 min).
5. **[heavy] Bootstrap:** `read -rs KONNECT_TOKEN && export KONNECT_TOKEN` then `scripts/bootstrap.sh`
   (Argo CD, namespaces, Secrets, Konnect for the active legs, root app). Watch:
   `kubectl get applications -n openshift-gitops -w`.
6. **Check:** `curl -s http://gslb-gslb-sim.localtest.me/orders/1` → 401;
   `T=$(scripts/get-token.sh normaluser); curl -s -H "Authorization: Bearer $T" http://gslb-gslb-sim.localtest.me/orders/1`.
   Swagger: http://blocking-blocking.localtest.me/swagger (from the Windows browser too).
7. **Tests, one leg:** `python3 -m venv ~/.venv && ~/.venv/bin/pip install -r tests/acceptance/requirements.txt`,
   then `~/.venv/bin/pytest tests/acceptance -v` (2-leg tests are skipped).
8. **[heavy] Multi-leg tests:** `scripts/leg.sh up leg2`, run the tests again, `scripts/leg.sh down leg2`.
9. **See it:** `scripts/k3d/ui.sh argocd` (Argo CD UI on http://localhost:8080 while it runs), `scripts/k3d/ui.sh headlamp`
   (kubeconfig for the Headlamp desktop app on Windows), or `kubectl get pods -A`.
10. **Pause / resume:** `scripts/k3d/cluster.sh stop` frees the memory; `start` brings it all back.

The blocking service image: the first push to GitHub triggers `.github/workflows/blocking-service-image.yml`.
If the GHCR package is private, either make it public (GitHub → Packages → kong-poc/blocking-service →
Package settings) or `export GHCR_PULL_TOKEN=<read:packages token>` before `scripts/create-secrets.sh` and set
`image.pullSecret: ghcr-pull` in `charts/blocking-service/values.yaml`.

---

# OpenShift path

## Phase 0 — workstation and OpenShift Local

1. Hardware check (see "Profiles" below). Install: `crc` (OpenShift Local), `oc`, `helm`, `git`, `jq`, `openssl`,
   `python3` (+ `pip`), `k6` (only for test 13).
2. Red Hat account (free) → download the pull secret from
   https://console.redhat.com/openshift/create/local → save as `~/.crc/pull-secret.txt`.
3. Start the cluster:
   ```bash
   scripts/crc-setup.sh small            # or: full
   eval "$(crc oc-env)"
   oc login -u kubeadmin https://api.crc.testing:6443   # password from: crc console --credentials
   ```
   **Check:** `oc get nodes` → `Ready`; `oc get crd httproutes.gateway.networking.k8s.io` exists.

### Profiles

| Profile | CRC VM | Host needs | Kong gateways per leg |
|---|---|---|---|
| `small` | 6 vCPU, 18 GiB, 80 GB | ≥ 8 cores, ≥ 32 GB RAM, 100 GB free SSD | 1 (HPA 1–2), smaller requests |
| `full` | 10 vCPU, 28 GiB, 100 GB | ≥ 12 cores, ≥ 48 GB RAM | 2 (HPA 2–5) |

Profile per leg: `profile:` in `environments/<leg>.yaml`. Cluster monitoring is off in both (saves ~4 GiB).
On Windows, OpenShift Local needs Hyper-V, so **Windows Pro, Enterprise or Education** — not Home.
If no workstation fits, ask for a test cluster: [CLUSTER-REQUEST.md](CLUSTER-REQUEST.md).

## Phase 1 — prerequisites and repo

```bash
git clone https://github.com/Efrat-Gortler/kong-poc.git && cd kong-poc
scripts/render-all.sh          # every chart, every leg, as ArgoCD layers it -> rendered/
```
**Check:** "all rendered". Look at `rendered/leg1/kong.yaml` for `KONG_PLUGINS` containing `blocklist`.

Tokens (only as environment variables, in the shell that runs the scripts):
```bash
read -rs KONNECT_TOKEN && export KONNECT_TOKEN     # Konnect personal access token (EU org)
read -rs GITHUB_TOKEN  && export GITHUB_TOKEN      # fine-grained, read-only "Contents" on kong-poc
```

## Phase 2 — bootstrap (namespaces, GitOps operator, Secrets, Konnect, root app)

```bash
scripts/bootstrap.sh          # asks before installing the operator and before granting cluster-admin to ArgoCD
git add charts/kong-values && git commit -m "Konnect control plane IDs" && git push
```
**Check:**
- `oc get applications -n openshift-gitops` → all `Synced` / `Healthy` within ~10 min
  (`leg*-opa` stays Progressing until the blocking service image is built — Phase 6).
- Konnect UI: control planes `poc-leg1`, `poc-leg2` (type Kong Ingress Controller) show the synced config.
- Note the trial start date in README.md.

## Phase 3 — Kong per leg, routing only

```bash
for l in leg1 leg2; do oc get pods -n $l; done
oc get pods -n leg1 --show-labels | grep gateway        # confirm labels for the egress NetworkPolicy
oc exec -n leg1 deploy/kong-leg1-gateway -- kong version
oc exec -n leg1 deploy/kong-leg1-gateway -- curl -s localhost:8001/license | jq '.license.expiration'
```
**Check:** Kong version is 3.14.x; `/license` returns an expiration date (Enterprise plugins will load).
If the image tag is wrong, fix `gateway.image.tag` in `charts/kong-values/values.yaml`, push.
Optionally enable egress policies: set `networkPolicies.egress.enabled: true` (and the selector) in `charts/kong-global/values.yaml`.

## Phase 4–5 — authentication and rate limiting

Already deployed by Phase 2. Smoke test:
```bash
T=$(scripts/get-token.sh normaluser)
curl -sk https://gslb-gslb-sim.apps-crc.testing/orders/1                          # 401
curl -sk -H "Authorization: Bearer $T" https://gslb-gslb-sim.apps-crc.testing/orders/1 | jq .   # 200, x-caller-id
curl -sk -o /dev/null -D - -H "Authorization: Bearer $T" https://gslb-gslb-sim.apps-crc.testing/users/limited/a | grep -i ratelimit
```
Check plugin field names against the running version if something is rejected:
`oc exec -n leg1 deploy/kong-leg1-gateway -- curl -s localhost:8001/schemas/plugins/openid-connect | jq '.fields'`
and KIC events: `oc get events -n leg1 --field-selector reason=KongConfigurationApplyFailed`.

## Phase 6 — blocking service

The BuildConfig starts on creation; follow it (it also runs the unit tests):
```bash
oc logs -n blocking -f bc/blocking-service
oc rollout status -n blocking deploy/blocking-service
```
Swagger: `https://blocking-blocking.apps-crc.testing/swagger` → *Authorize* → paste `scripts/get-token.sh opsadmin`.
CLI: `scripts/block.sh user 666efratg@corp.local "test" 60`, `scripts/block.sh list`.

## Phase 7–8 — Lua plugin and OPA

`blocking.mode: lua` is the default. Unit tests:
```bash
(cd kong-plugins/blocklist && busted spec/)     # needs lua 5.1/luajit + busted
opa test opa/policy -v                          # needs the opa binary (same version: 1.4.2)
```
Switch mechanism: edit `blocking.mode` in `charts/kong-global/values.yaml` (`lua` | `opa` | `both-observe` | `off`), push.

## Phase 9 — GitOps / no restarts

```bash
scripts/check-restarts.sh snapshot /tmp/before.txt
# change a threshold in charts/mock-service/values-orders.yaml, commit, push, wait for Synced
scripts/check-restarts.sh compare /tmp/before.txt      # OK: same Kong pods, no restarts
```

## Phase 10 — acceptance tests and report

```bash
pip install -r tests/acceptance/requirements.txt
cd tests/acceptance
pytest -v                                   # 1-8, 11, 12 (safe)
pytest -v -m destructive                    # 9: blocking service down, Redis down
ALLOW_GIT_PUSH=1 pytest -v -m gitops        # 10: pushes a probe route, then reverts it
cd ../.. && ALLOW_GIT_PUSH=1 SYSTEM_CLIENT_SECRET=$(oc get secret idp-test-credentials -n idp -o jsonpath='{.data.KC_SYSTEM_CLIENT_SECRET}' | base64 -d) \
  tests/acceptance/run-blocking-comparison.sh   # 8 per mechanism + 13 latency (off / lua / opa)
```
Results: `tests/results/*.json` → `docs/TEST-REPORT.md`.

## Day-2

| Task | Command |
|---|---|
| Drain / restore a leg | `scripts/drain-leg.sh leg2 drain` / `ready` / `status` |
| Token for a user / client | `scripts/get-token.sh 777danag` / `reports-service` |
| Rebuild blocking service | `oc start-build blocking-service -n blocking --follow` |
| Reload Lua plugin code | push, then `oc rollout restart deploy/kong-<leg>-gateway -n <leg>` (code, not config) |
| Add a leg | `scripts/add-leg.sh leg3` → commit, push → `scripts/bootstrap.sh` |
| Keycloak admin | `https://keycloak-idp.apps-crc.testing/admin` — `oc get secret keycloak-admin -n idp -o jsonpath='{.data.password}' \| base64 -d` |
| ArgoCD UI | `oc get route openshift-gitops-server -n openshift-gitops` — log in with OpenShift |
| Konnect trial ending | new trial or a `license.json` → `KongLicense` resource (see OPEN-QUESTIONS) |
| Stop / start CRC | `crc stop` / `crc start` (state is kept; Keycloak re-imports the realms) |
