#!/usr/bin/env bash
# Links one leg's KIC to Kong Konnect (license source for the POC):
#   1. creates (or finds) the control plane "poc-<leg>" of type Kong Ingress Controller
#   2. creates a client certificate, uploads it, stores it as Secret konnect-client-tls
#   3. writes the (non-secret) control plane ID and telemetry host into
#      charts/kong-values/values-<leg>.yaml  -> commit + push afterwards
#
# Usage: KONNECT_TOKEN=... scripts/konnect-setup.sh leg1
# KONNECT_TOKEN is only read from the environment; it is never printed or stored.
source "$(dirname "$0")/lib.sh"
need oc curl jq openssl
leg="${1:?usage: $0 <leg>}"
: "${KONNECT_TOKEN:?export KONNECT_TOKEN first (Konnect personal access token)}"
KONNECT_API="${KONNECT_API:-https://eu.api.konghq.com}"
CP_NAME="poc-${leg}"
VALUES="$REPO_ROOT/charts/kong-values/values-${leg}.yaml"
[[ -f "$VALUES" ]] || die "missing $VALUES (run scripts/add-leg.sh $leg first)"

kapi() { # method path [json]
  local args=(--no-progress-meter --fail-with-body -X "$1" "$KONNECT_API$2"
              -H "Authorization: Bearer $KONNECT_TOKEN" -H "Content-Type: application/json")
  [[ $# -ge 3 ]] && args+=(--data "$3")
  curl "${args[@]}"
}

log "Konnect API: $KONNECT_API"
cp_json="$(kapi GET "/v2/control-planes?filter%5Bname%5D%5Beq%5D=${CP_NAME}" | jq '.data[0] // empty')"
if [[ -z "$cp_json" ]]; then
  log "creating control plane $CP_NAME (CLUSTER_TYPE_K8S_INGRESS_CONTROLLER)"
  cp_json="$(kapi POST /v2/control-planes \
    "$(jq -nc --arg n "$CP_NAME" '{name:$n, cluster_type:"CLUSTER_TYPE_K8S_INGRESS_CONTROLLER", labels:{project:"kong-poc"}}')")"
else
  log "control plane $CP_NAME exists"
fi
cp_type="$(jq -r '.config.cluster_type' <<<"$cp_json")"
[[ "$cp_type" == "CLUSTER_TYPE_K8S_INGRESS_CONTROLLER" ]] || die "$CP_NAME has type $cp_type, expected CLUSTER_TYPE_K8S_INGRESS_CONTROLLER"
cp_id="$(jq -r '.id' <<<"$cp_json")"
tp_host="$(jq -r '.config.telemetry_endpoint' <<<"$cp_json" | sed -E 's#^https?://##; s#:443$##')"
log "control plane id: $cp_id  telemetry: $tp_host"

if oc get secret konnect-client-tls -n "$leg" >/dev/null 2>&1; then
  log "Secret $leg/konnect-client-tls exists - keeping it"
else
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  openssl req -new -x509 -nodes -newkey rsa:2048 -days 365 -subj "/CN=kong-poc-${leg}/C=IL" \
    -keyout "$tmp/tls.key" -out "$tmp/tls.crt" 2>/dev/null
  cert="$(awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}' "$tmp/tls.crt")"
  kapi POST "/v2/control-planes/${cp_id}/dp-client-certificates" "{\"cert\": \"${cert}\"}" >/dev/null
  oc create secret tls konnect-client-tls -n "$leg" --cert="$tmp/tls.crt" --key="$tmp/tls.key" >/dev/null
  log "uploaded client certificate and created Secret $leg/konnect-client-tls"
fi

# KIC's Konnect host for the EU region. Check it answers before relying on it.
kic_host="$(grep -E '^\s*apiHostname:' "$REPO_ROOT/charts/kong-values/values.yaml" | head -1 | sed -E 's/.*"(.*)".*/\1/')"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${kic_host}/" || true)"
[[ "$code" == "000" ]] && warn "https://${kic_host} did not answer - check the KIC API hostname for the EU region" \
                       || log "KIC Konnect host ${kic_host} reachable (HTTP $code)"

LEG_UP="$(tr "[:lower:]" "[:upper:]" <<<"$leg")"   # bash 3 (macOS) has no ${x^^}
sed -i.bak -E "s/KONNECT_CP_ID_${LEG_UP}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/${cp_id}/; \
               s/KONNECT_TP_HOST_${LEG_UP}|[a-z0-9]+\.eu\.tp0\.konghq\.com/${tp_host}/g" "$VALUES"
rm -f "$VALUES.bak"
log "updated ${VALUES#$REPO_ROOT/} - commit and push it"
