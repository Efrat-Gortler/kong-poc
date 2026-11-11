#!/usr/bin/env bash
# GET a path from one leg's Kong Admin API (read-only; DB-less, config comes from KIC).
# The kong-gateway image has no curl, so this goes through a short-lived port-forward.
#   scripts/kong-admin.sh leg1 /                       # version, .license (DB-less: no /license endpoint)
#   scripts/kong-admin.sh leg1 /plugins | jq '.data[].name'
#   scripts/kong-admin.sh leg1 /schemas/plugins/openid-connect | jq '.fields'
source "$(dirname "$0")/lib.sh"
need oc curl
leg="${1:?usage: $0 <leg> <path>}"; path="${2:-/}"
port=$((20000 + RANDOM % 10000))
oc port-forward -n "$leg" "svc/kong-${leg}-gateway-admin" "$port:8444" >/dev/null 2>&1 &
pf=$!
trap 'kill $pf 2>/dev/null; wait $pf 2>/dev/null' EXIT
for _ in $(seq 1 40); do curl -sk -o /dev/null "https://localhost:$port/" && break; sleep 0.25; done
curl -sk "https://localhost:$port$path"
