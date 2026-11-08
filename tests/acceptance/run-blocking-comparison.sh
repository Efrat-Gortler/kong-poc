#!/usr/bin/env bash
# Runs the blocking tests (8) once per mechanism and the latency test (13) for
# off / lua / opa. Switches blocking.mode through Git (commit + push), waits for
# ArgoCD, then runs. Restores the original mode at the end.
#   ALLOW_GIT_PUSH=1 tests/acceptance/run-blocking-comparison.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/lib.sh
[[ "${ALLOW_GIT_PUSH:-0}" == "1" ]] || die "set ALLOW_GIT_PUSH=1 (this pushes commits that switch blocking.mode)"
VALUES=charts/kong-global/values.yaml
export GSLB_URL KEYCLOAK_URL   # from lib.sh (platform-aware), read by k6
original="$(grep -E '^  mode:' "$VALUES" | awk '{print $2}')"

set_mode() {
  sed -i.bak -E "s/^  mode: .*/  mode: $1/" "$VALUES" && rm -f "$VALUES.bak"
  git add "$VALUES"
  git commit -q -m "test: blocking.mode=$1" || true
  git push -q
  for leg in $(legs); do
    oc annotate application "$leg-kong-global" -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  done
  log "waiting for blocking.mode=$1 on every leg"
  for i in $(seq 1 60); do
    ok=1
    for leg in $(legs); do
      lua=$(oc get kongclusterplugin "$leg-blocklist" -o name 2>/dev/null || true)
      opa=$(oc get kongclusterplugin "$leg-opa" -o name 2>/dev/null || true)
      case "$1" in
        lua) [[ -n "$lua" && -z "$opa" ]] || ok=0 ;;
        opa) [[ -z "$lua" && -n "$opa" ]] || ok=0 ;;
        off) [[ -z "$lua" && -z "$opa" ]] || ok=0 ;;
      esac
    done
    [[ $ok == 1 ]] && { sleep 10; return 0; }   # + time for KIC to push to the gateways
    sleep 5
  done
  die "mode $1 did not reach every leg"
}

trap 'set_mode "$original"' EXIT
for mode in lua opa; do
  set_mode "$mode"
  pytest tests/acceptance/test_08_blocking.py -v
  MODE="$mode" k6 run --quiet tests/load/latency.js --summary-export "tests/results/latency-$mode.json"
done
set_mode off
MODE=off k6 run --quiet tests/load/latency.js --summary-export tests/results/latency-off.json
log "results in tests/results/ - copy the numbers into docs/TEST-REPORT.md"
