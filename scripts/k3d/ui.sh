#!/usr/bin/env bash
# Graphical views of the laptop cluster, without running UI pods all the time.
#   scripts/k3d/ui.sh argocd     # Argo CD UI at http://localhost:8080 until Ctrl+C (no login in core mode)
#   scripts/k3d/ui.sh headlamp   # writes a kubeconfig for Headlamp on Windows (%USERPROFILE%\.kube\config)
source "$(dirname "$0")/../lib.sh"
case "${1:-}" in
  argocd)
    need argocd kubectl
    log "Argo CD UI: http://localhost:8080 (also from the Windows browser). Ctrl+C to stop."
    kubectl config set-context --current --namespace=openshift-gitops >/dev/null
    trap 'kubectl config set-context --current --namespace=default >/dev/null' EXIT
    argocd admin dashboard --core --port 8080 ;;
  headlamp)
    need kubectl wslpath
    winhome="$(wslpath "$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')")"
    [[ -d "$winhome" ]] || die "could not find the Windows user folder"
    mkdir -p "$winhome/.kube"
    target="$winhome/.kube/config"
    if [[ -f "$target" ]] && ! grep -q 'k3d-kong-poc' "$target"; then
      cp "$target" "$target.bak.$(date +%s)"; warn "existing Windows kubeconfig backed up next to it"
    fi
    # k3d's API server is published on 0.0.0.0:<port>; Windows reaches it as localhost (WSL forwarding)
    kubectl config view --minify --flatten --context k3d-kong-poc | sed 's#https://0.0.0.0:#https://127.0.0.1:#' > "$target"
    log "wrote $target - open Headlamp on Windows, it shows the cluster k3d-kong-poc"
    log "Headlamp itself: https://headlamp.dev (Windows installer, no admin rights needed for a per-user install)" ;;
  *) die "usage: $0 argocd | headlamp" ;;
esac
