#!/usr/bin/env bash
# The k3d cluster (laptop path).
#   scripts/k3d/cluster.sh create | stop | start | delete | status
# One server node, no agents, no metrics-server (no HPA in the small profile),
# Traefik kept as the ingress for gslb / idp / blocking (host port 80 -> *.localtest.me).
source "$(dirname "$0")/../lib.sh"
need docker k3d kubectl
NAME=kong-poc
K3S_IMAGE=rancher/k3s:v1.35.10-k3s1

case "${1:-status}" in
  create)
    k3d cluster list "$NAME" >/dev/null 2>&1 && { log "cluster $NAME exists"; exit 0; }
    k3d cluster create "$NAME" --image "$K3S_IMAGE" --servers 1 --agents 0 \
      -p "80:80@loadbalancer" \
      --k3s-arg "--disable=metrics-server@server:0" \
      --wait --timeout 180s
    kubectl config use-context "k3d-$NAME" >/dev/null
    kubectl get nodes ;;
  stop)   k3d cluster stop "$NAME" ;;    # frees the memory; state is kept
  start)  k3d cluster start "$NAME" && kubectl config use-context "k3d-$NAME" >/dev/null ;;
  delete) confirm "Delete the k3d cluster $NAME and everything in it?" && k3d cluster delete "$NAME" ;;
  status) k3d cluster list; kubectl top node 2>/dev/null || docker stats --no-stream --format '{{.Name}}  {{.MemUsage}}' ;;
  *) die "usage: $0 create|stop|start|delete|status" ;;
esac
