#!/usr/bin/env bash
# Option A (Kong Manager, hybrid mode): one-time setup of what Argo CD cannot create from Git.
#   1. namespaces konga-cp, konga-leg1, konga-leg2, konga-gslb      (cluster-wide: asks first)
#   2. Secrets, random values, never written to Git or disk:
#        konga-cp/konga-postgres        username, password  (Kong's Postgres)
#        <cp and dp namespaces>/kong-cluster-cert   tls.crt, tls.key  (hybrid mTLS, cluster_mtls: shared)
# The Argo CD project and applications come from Git (argocd/apps/option-a/), picked up by the root app.
# Safe to re-run: existing namespaces and Secrets are kept. ASSUME_YES=1 skips the prompt.
source "$(dirname "$0")/../lib.sh"
need oc openssl

CP_NS=konga-cp
DP_NS=(konga-leg1 konga-leg2)
ALL_NS=("$CP_NS" "${DP_NS[@]}" konga-gslb)

log "1/2 namespaces: ${ALL_NS[*]}"
missing=()
for ns in "${ALL_NS[@]}"; do oc get ns "$ns" >/dev/null 2>&1 || missing+=("$ns"); done
if (( ${#missing[@]} )); then
  confirm "Create namespaces ${missing[*]} (cluster-wide)?" || die "aborted"
  for ns in "${missing[@]}"; do oc create ns "$ns" >/dev/null; done
fi
for ns in "${ALL_NS[@]}"; do oc label ns "$ns" kong-poc/option=a --overwrite >/dev/null; done
for ns in "${DP_NS[@]}"; do oc label ns "$ns" kong-poc/role=leg-a --overwrite >/dev/null; done

log "2/2 secrets"
if oc get secret konga-postgres -n "$CP_NS" >/dev/null 2>&1; then
  log "keep   $CP_NS/konga-postgres"
else
  oc create secret generic konga-postgres -n "$CP_NS" \
    --from-literal=username=kong --from-literal=password="$(random_secret)" >/dev/null
  log "create $CP_NS/konga-postgres"
fi

# One certificate for the control plane and every data plane (cluster_mtls: shared). The CN is
# what Kong expects in shared mode; DPs only trust a CP that presents this certificate.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
if oc get secret kong-cluster-cert -n "$CP_NS" >/dev/null 2>&1; then
  oc get secret kong-cluster-cert -n "$CP_NS" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$tmp/tls.crt"
  oc get secret kong-cluster-cert -n "$CP_NS" -o jsonpath='{.data.tls\.key}' | base64 -d > "$tmp/tls.key"
  log "keep   $CP_NS/kong-cluster-cert"
else
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -nodes -days 1095 \
    -subj "/CN=kong_clustering" -keyout "$tmp/tls.key" -out "$tmp/tls.crt" 2>/dev/null
  oc create secret tls kong-cluster-cert -n "$CP_NS" --cert="$tmp/tls.crt" --key="$tmp/tls.key" >/dev/null
  log "create $CP_NS/kong-cluster-cert"
fi
for ns in "${DP_NS[@]}"; do
  if oc get secret kong-cluster-cert -n "$ns" >/dev/null 2>&1; then
    log "keep   $ns/kong-cluster-cert"
  else
    oc create secret tls kong-cluster-cert -n "$ns" --cert="$tmp/tls.crt" --key="$tmp/tls.key" >/dev/null
    log "create $ns/kong-cluster-cert"
  fi
done

log "done. Argo CD creates the rest from argocd/apps/option-a/: oc get applications -n openshift-gitops -l kong-poc/option=a"
