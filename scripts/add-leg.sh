#!/usr/bin/env bash
# Adds a leg by copying the last existing one and renaming it. Then: review, commit, push,
# and run scripts/bootstrap.sh again (namespace, Secrets, Konnect control plane).
#   scripts/add-leg.sh leg3
source "$(dirname "$0")/lib.sh"
new="${1:?usage: $0 <legN>}"
[[ "$new" =~ ^leg[0-9]+$ ]] || die "leg names look like leg3"
[[ -f "$REPO_ROOT/environments/$new.yaml" ]] && die "$new already exists"
src="$(legs | sort -V | tail -1)"
next_db=$(( $(grep -h routeLimitDatabase "$REPO_ROOT"/environments/*.yaml | awk '{print $2}' | sort -n | tail -1) + 1 ))
up_src="$(tr '[:lower:]' '[:upper:]' <<<"$src")"; up_new="$(tr '[:lower:]' '[:upper:]' <<<"$new")"

copy() { # file
  local from="$1" to="${1/$src/$new}"
  sed -e "s/$src/$new/g" -e "s/$up_src/$up_new/g" "$from" > "$to"
  log "created ${to#$REPO_ROOT/}"
}

copy "$REPO_ROOT/environments/$src.yaml"
sed -i.bak -E "s/(routeLimitDatabase:).*/\1 $next_db/" "$REPO_ROOT/environments/$new.yaml" && rm -f "$REPO_ROOT/environments/$new.yaml.bak"
for f in "$REPO_ROOT"/charts/*/values-"$src".yaml; do copy "$f"; done
# Konnect IDs are per leg: reset to placeholders for konnect-setup.sh
sed -i.bak -E "s/controlPlaneID: .*/controlPlaneID: \"KONNECT_CP_ID_$up_new\"/; s/\"[a-z0-9]+\.eu\.tp0\.konghq\.com(:443)?\"/\"KONNECT_TP_HOST_$up_new\1\"/g" \
  "$REPO_ROOT/charts/kong-values/values-$new.yaml" && rm -f "$REPO_ROOT/charts/kong-values/values-$new.yaml.bak"

# GSLB simulator: one more backend line
python3 - "$REPO_ROOT/charts/gslb-sim/values.yaml" "$new" <<'PY'
import sys, re
path, leg = sys.argv[1], sys.argv[2]
s = open(path).read()
line = f"  - name: {leg}\n    address: kong-{leg}-gateway-proxy.{leg}.svc.cluster.local:80\n"
s = re.sub(r"(legs:\n(?:  - name: .*\n    address: .*\n)+)", lambda m: m.group(1) + line, s)
open(path, "w").write(s)
PY
log "added $new to charts/gslb-sim/values.yaml"
log "route-wide limit DB for $new: $next_db (per-user limit stays on DB 0, shared)"
log "next: git add -A && git commit -m 'Add $new' && git push && scripts/bootstrap.sh"
