#!/usr/bin/env bash
# Renders every chart for every leg exactly the way ArgoCD layers the value files,
# and runs helm lint. Output: rendered/<leg>/<app>.yaml (git-ignored).
#   scripts/render-all.sh            # needs helm (and network for kong/ingress)
source "$(dirname "$0")/lib.sh"
need helm
out="$REPO_ROOT/rendered"; rm -rf "$out"; mkdir -p "$out"
helm dependency build "$REPO_ROOT/charts/mock-service" >/dev/null

layer() { # chart app leg -> -f args (missing files skipped, like ArgoCD ignoreMissingValueFiles)
  local c="$REPO_ROOT/charts/$1" profile
  profile="$(awk '/^profile:/ {print $2}' "$REPO_ROOT/environments/$3.yaml")"
  for f in "$c/values.yaml" "$c/values-$2.yaml" "$c/values-profile-$profile.yaml" "$c/values-$3.yaml" "$REPO_ROOT/environments/$3.yaml"; do
    [[ -f "$f" ]] && printf -- '-f\n%s\n' "$f"
  done
}

fail=0
for leg in $(legs); do
  mkdir -p "$out/$leg"
  for pair in kong-global:kong-global opa:opa orders:mock-service reports:mock-service users:mock-service; do
    app="${pair%%:*}"; chart="${pair##*:}"
    args=(); while IFS= read -r a; do args+=("$a"); done < <(layer "$chart" "$app" "$leg")   # bash 3 safe
    if helm template "$app" "$REPO_ROOT/charts/$chart" -n "$leg" "${args[@]}" > "$out/$leg/$app.yaml" 2>"$out/$leg/$app.err"; then
      log "$leg/$app: $(grep -c '^kind:' "$out/$leg/$app.yaml") objects"
    else
      warn "$leg/$app FAILED:"; cat "$out/$leg/$app.err" >&2; fail=1
    fi
  done
  profile="$(awk '/^profile:/ {print $2}' "$REPO_ROOT/environments/$leg.yaml")"
  if helm template "kong-$leg" ingress --repo https://charts.konghq.com --version 0.24.0 -n "$leg" --skip-crds \
       -f "$REPO_ROOT/charts/kong-values/values.yaml" -f "$REPO_ROOT/charts/kong-values/values-profile-$profile.yaml" \
       -f "$REPO_ROOT/charts/kong-values/values-$leg.yaml" > "$out/$leg/kong.yaml" 2>"$out/$leg/kong.err"; then
    log "$leg/kong: $(grep -c '^kind:' "$out/$leg/kong.yaml") objects"
  else
    warn "$leg/kong FAILED:"; cat "$out/$leg/kong.err" >&2; fail=1
  fi
done
for chart in redis idp blocking-service gslb-sim; do
  if helm template "$chart" "$REPO_ROOT/charts/$chart" > "$out/$chart.yaml" 2>"$out/$chart.err"; then
    log "shared/$chart: $(grep -c '^kind:' "$out/$chart.yaml") objects"
  else
    warn "shared/$chart FAILED:"; cat "$out/$chart.err" >&2; fail=1
  fi
done
for chart in "$REPO_ROOT"/charts/*/Chart.yaml; do helm lint "$(dirname "$chart")" --quiet >/dev/null 2>&1 || warn "lint: $(dirname "$chart")"; done
[[ $fail == 0 ]] && log "all rendered into rendered/" || die "rendering failed"
