#!/usr/bin/env bash
# Proves that a config change did not restart Kong.
#   scripts/check-restarts.sh snapshot /tmp/before.txt
#   ... change routes / thresholds in Git, wait for ArgoCD ...
#   scripts/check-restarts.sh compare  /tmp/before.txt     # exit 1 if any Kong pod changed
# Records pod UID + restart count of every Kong gateway and controller pod in every leg.
source "$(dirname "$0")/lib.sh"
need oc
mode="${1:?snapshot|compare}"; file="${2:?file}"

current() {
  for leg in $(legs); do
    oc get pods -n "$leg" -l "app.kubernetes.io/instance=kong-$leg" \
      -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.metadata.uid} {range .status.containerStatuses[*]}{.restartCount},{end}{"\n"}{end}'
  done | sort
}

case "$mode" in
  snapshot) current > "$file"; log "recorded $(wc -l < "$file") Kong pods into $file" ;;
  compare)
    now="$(current)"
    if diff <(cat "$file") <(echo "$now") >/dev/null; then
      log "OK: same Kong pods, no restarts ($(wc -l < "$file") pods)"
    else
      warn "Kong pods changed:"; diff <(cat "$file") <(echo "$now") || true; exit 1
    fi ;;
  *) die "usage: $0 snapshot|compare <file>" ;;
esac
