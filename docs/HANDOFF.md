# Handoff — read this first (for a new Claude session on the POC machine)

You are continuing a Kong Enterprise POC that was built in an earlier Claude conversation.
The user writes Hebrew: answer her in Hebrew; keep code, configs and repo docs in English.
Background and decisions: `README.md`, `docs/ARCHITECTURE.md`, `docs/RUNBOOK.md` ("GCP path"),
`docs/OPEN-QUESTIONS.md`. The original brief is "option C": Kong Enterprise DB-less managed by KIC
from Git (Argo CD) + a separate blocking service with Swagger; prove it with the 13 acceptance tests
in `tests/acceptance` and compare two blocking mechanisms (Lua plugin vs OPA).

## Where things run
- **This machine:** GCP VM `kong-poc-crc` (n2-standard-8, CentOS Stream 9, europe-west1-b),
  static IP 35.240.80.253, stops itself at 22:00 Asia/Jerusalem (start: Cloud Shell
  `bash scripts/gcp/vm.sh start`, or the Compute Engine console).
- **OpenShift:** OpenShift Local (CRC 2.63) with the **OKD** preset (the user has no Red Hat account),
  7 vCPU / 26 GiB, cluster monitoring off. HAProxy on the VM publishes 80/443/6443 of the CRC VM.
  Install log: `~/crc-setup.log` (script `scripts/gcp/crc-setup.sh`). `eval "$(crc oc-env)"` for `oc`.
- **Repo:** `~/kong-poc` = github.com/Efrat-Gortler/kong-poc (public; owner may make it private).
  `cluster/platform.yaml` is `openshift`; both legs (`leg1`, `leg2`) are active in `environments/`.
- **The user's Windows browser** reaches the console/routes via hosts entries (`scripts/windows/hosts-crc.cmd`,
  firewall allows 188.64.206.0/24 on 80/443/6443/22).

## Status when this was written
- Done: all code, charts, scripts, tests, docs; charts render for both platforms; Lua unit tests pass;
  the mini token issuer was verified; VM created; OKD installation started.
- Next, in order:
  1. Confirm `crc status` is Running and `oc get nodes` Ready (`tail ~/crc-setup.log`).
  2. User runs `hosts-crc.cmd` on Windows (admin); console: https://console-openshift-console.apps-crc.testing
     (`crc console --credentials` prints kubeadmin — never paste it into chats or files).
  3. `oc login -u kubeadmin https://api.crc.testing:6443`
  4. `gh auth login` (device flow; the user has no smartphone — use the browser code flow).
  5. `read -rs KONNECT_TOKEN && export KONNECT_TOKEN` (the user types it; never echo/store it), then
     `scripts/bootstrap.sh`. On OKD there is no OpenShift GitOps operator, so bootstrap installs upstream
     Argo CD core (nonroot-v2 SCC for its SAs). It creates Konnect control planes `poc-leg1/2` (EU) and
     commits their IDs. **The Konnect 30-day trial effectively starts here — note the date in README.md.**
  6. Watch `oc get applications -n openshift-gitops`; verify `/license` per leg before Enterprise plugins.
  7. Tests: `~/.venv/bin/pytest tests/acceptance -v`, then `-m destructive`, `ALLOW_GIT_PUSH=1 -m gitops`,
     then `tests/acceptance/run-blocking-comparison.sh` (needs k6). Fill `docs/TEST-REPORT.md`.
- Expect first-run issues to fix in Git (never by hand in the cluster): exact Kong image patch tag,
  plugin field names for the installed Kong version (`/schemas/plugins/<name>`), SCC/securityContext
  details, Gateway API CRD versions on OKD. Record deviations in README.md.

## Rules carried over
- No secrets in Git, files, logs or chat (Konnect PAT, GitHub tokens, kubeadmin, pull secrets).
- Config changes go through Git + Argo CD; blocks only through the blocking service API.
- Ask before cluster-wide or destructive steps; commit in small steps with clear messages.
