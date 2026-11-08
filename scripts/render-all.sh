#!/usr/bin/env bash
# Renders every chart for every ACTIVE leg exactly the way the ApplicationSets layer the
# value files, and runs helm lint. Output: rendered/<leg>/<app>.yaml (git-ignored).
#   scripts/render-all.sh                    # platform from cluster/platform.yaml
#   POC_PLATFORM=openshift scripts/render-all.sh
source "$(dirname "$0")/lib.sh"
need helm
out="$REPO_ROOT/rendered"; rm -rf "$out"; mkdir -p "$out"
helm dependency build "$REPO_ROOT/charts/mock-service" >/dev/null
P="$POC_PLATFORM"
cluster_values="$REPO_ROOT/cluster/values-$P.yaml"
log "platform: $P"

args_for() { # chart app leg|"" -> one value file per line (missing files skipped)
  local c="$REPO_ROOT/charts/$1" profile=""
  [[ -n "$3" ]] && profile="$(awk '/^profile:/ {print $2}' "$REPO_ROOT/environments/$3.yaml")"
  for f in "$c/values.yaml" "$c/values-$2.yaml" "$c/values-platform-$P.yaml" \
           ${profile:+"$c/values-profile-$profile.yaml"} ${3:+"$c/values-$3.yaml"} \
           "$cluster_values" ${3:+"$REPO_ROOT/environments/$3.yaml"}; do
    [[ -f "$f" ]] && printf -- '-f\n%s\n' "$f"
  done
}

render() { # name chart app leg ns
  local args=() a
  while IFS= read -r a; do args+=("$a"); done < <(args_for "$2" "$3" "$4")
  if helm template "$3" "$REPO_ROOT/charts/$2" -n "$5" "${args[@]}" > "$out/$1.yaml" 2>"$out/$1.err"; then
    log "$1: $(grep -c '^kind:' "$out/$1.yaml") objects ($(grep '^kind:' "$out/$1.yaml" | sort | uniq -c | awk '{printf "%s %s, ", $1, $3}' | sed 's/, $//'))"
  else
    warn "$1 FAILED:"; cat "$out/$1.err" >&2; fail=1
  fi
}

fail=0
for leg in $(legs); do
  mkdir -p "$out/$leg"
  for pair in kong-global:kong-global opa:opa orders:mock-service reports:mock-service users:mock-service; do
    render "$leg/${pair%%:*}" "${pair##*:}" "${pair%%:*}" "$leg" "$leg"
  done
  profile="$(awk '/^profile:/ {print $2}' "$REPO_ROOT/environments/$leg.yaml")"
  if helm template "kong-$leg" ingress --repo https://charts.konghq.com --version 0.24.0 -n "$leg" --skip-crds \
       -f "$REPO_ROOT/charts/kong-values/values.yaml" -f "$REPO_ROOT/charts/kong-values/values-platform-$P.yaml" \
       -f "$REPO_ROOT/charts/kong-values/values-profile-$profile.yaml" \
       -f "$REPO_ROOT/charts/kong-values/values-$leg.yaml" > "$out/$leg/kong.yaml" 2>"$out/$leg/kong.err"; then
    log "$leg/kong: $(grep -c '^kind:' "$out/$leg/kong.yaml") objects"
  else
    warn "$leg/kong FAILED:"; cat "$out/$leg/kong.err" >&2; fail=1
  fi
done
for pair in redis:gw-shared idp:idp blocking-service:blocking gslb-sim:gslb-sim; do
  mkdir -p "$out/shared"; render "shared/${pair%%:*}" "${pair%%:*}" "${pair%%:*}" "" "${pair##*:}"
done
for chart in "$REPO_ROOT"/charts/*/Chart.yaml; do helm lint "$(dirname "$chart")" --quiet >/dev/null 2>&1 || warn "lint: $(dirname "$chart")"; done
[[ $fail == 0 ]] && log "all rendered into rendered/" || die "rendering failed"
