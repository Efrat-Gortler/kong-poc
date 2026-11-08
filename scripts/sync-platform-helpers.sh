#!/usr/bin/env bash
# Copies charts/kong-global/templates/_platform.tpl (the master) into every other application chart.
source "$(dirname "$0")/lib.sh"
master="$REPO_ROOT/charts/kong-global/templates/_platform.tpl"
for c in "$REPO_ROOT"/charts/*/; do
  [[ -f "$c/Chart.yaml" ]] || continue
  grep -q '^type: library' "$c/Chart.yaml" && continue
  [[ "$c/templates/_platform.tpl" -ef "$master" ]] && continue
  mkdir -p "$c/templates" && cp "$master" "$c/templates/_platform.tpl" && log "synced ${c#$REPO_ROOT/}"
done
