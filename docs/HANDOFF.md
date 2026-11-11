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
  7 vCPU / 26 GiB, cluster monitoring off. CRC uses its default user network mode: the crc daemon publishes 80/443, HAProxy adds
  `<host IP>:6443 -> 127.0.0.1:6443`. Lingering + user unit `crc-autostart.service` keep/start it across SSH logouts and reboots.
  Install log: `~/crc-setup.log` (script `scripts/gcp/crc-setup.sh`). `eval "$(crc oc-env)"` for `oc`.
- **Repo:** `~/kong-poc` = github.com/Efrat-Gortler/kong-poc (public; owner may make it private).
  `cluster/platform.yaml` is `openshift`; both legs (`leg1`, `leg2`) are active in `environments/`.
- **The user's Windows browser** reaches the console/routes via hosts entries (`scripts/windows/hosts-crc.cmd`,
  firewall allows 188.64.206.0/24 on 80/443/6443/22).

## Status (2026-11-11)
- Done: OKD up (lingering + `crc-autostart` user unit, HAProxy for 6443 only), bootstrap, Konnect (trial
  from 2026-11-11), all Argo CD apps Synced/Healthy, all 13 tests pass (`pytest tests/acceptance`, `-m destructive`,
  `-m gitops`, `run-blocking-comparison.sh`), `docs/TEST-REPORT.md` filled with a recommendation (Lua plugin).
- First-run fixes are listed in README "Deviations". `scripts/kong-admin.sh <leg> <path>` reads a leg's Admin API.
- Open decisions for the user: TEST-REPORT findings 1 (tokens without `caller_id`) and 2 (client identity
  headers reach upstreams); make the repo private; rename the test users.
- Daily: Cloud Shell `bash scripts/gcp/vm.sh start`; OpenShift comes back by itself (~10 min).

## Rules carried over
- No secrets in Git, files, logs or chat (Konnect PAT, GitHub tokens, kubeadmin, pull secrets).
- Config changes go through Git + Argo CD; blocks only through the blocking service API.
- Ask before cluster-wide or destructive steps; commit in small steps with clear messages.
