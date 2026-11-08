#!/usr/bin/env bash
# Brings a leg up or parks it (to save memory, the laptop runs one leg until the
# multi-leg tests). Moves environments/<leg>.yaml <-> environments/standby/, commits,
# pushes; ArgoCD then creates or removes that leg's apps.
#   scripts/leg.sh up leg2      # + namespace, Secrets and Konnect link for the leg
#   scripts/leg.sh down leg2
#   scripts/leg.sh list
source "$(dirname "$0")/lib.sh"
need git
action="${1:-list}"; leg="${2:-}"
active="$REPO_ROOT/environments/$leg.yaml"; parked="$REPO_ROOT/environments/standby/$leg.yaml"

case "$action" in
  list)
    echo "active: $(legs | tr '\n' ' ')"
    echo "parked: $(for f in "$REPO_ROOT"/environments/standby/*.yaml; do [[ -e "$f" ]] && basename "$f" .yaml; done | tr '\n' ' ')" ;;
  up)
    [[ -f "$parked" ]] || die "no parked leg $leg (environments/standby/$leg.yaml)"
    oc get ns "$leg" >/dev/null 2>&1 || oc create ns "$leg" >/dev/null
    oc label ns "$leg" kong-poc/role=leg --overwrite >/dev/null
    git -C "$REPO_ROOT" mv "environments/standby/$leg.yaml" "environments/$leg.yaml"
    "$REPO_ROOT/scripts/create-secrets.sh"
    if [[ -n "${KONNECT_TOKEN:-}" ]]; then "$REPO_ROOT/scripts/konnect-setup.sh" "$leg"
    else warn "KONNECT_TOKEN not set: $leg will have no Enterprise license until scripts/konnect-setup.sh $leg runs"; fi
    git -C "$REPO_ROOT" add -A environments charts/kong-values
    git -C "$REPO_ROOT" commit -q -m "Bring up $leg"
    git -C "$REPO_ROOT" push -q
    log "$leg is coming up (ArgoCD, ~2-3 min). Watch: oc get pods -n $leg -w" ;;
  down)
    [[ -f "$active" ]] || die "$leg is not active"
    [[ "$(legs | wc -l)" -gt 1 ]] || die "$leg is the last active leg"
    git -C "$REPO_ROOT" mv "environments/$leg.yaml" "environments/standby/$leg.yaml"
    git -C "$REPO_ROOT" commit -q -m "Park $leg"
    git -C "$REPO_ROOT" push -q
    log "$leg parked: ArgoCD removes its apps (the namespace and its Secrets stay for next time)" ;;
  *) die "usage: $0 up|down <leg> | list" ;;
esac
