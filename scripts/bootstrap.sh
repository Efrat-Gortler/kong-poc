#!/usr/bin/env bash
# One-time bootstrap of an empty cluster. After this, everything comes from Git via ArgoCD.
#
#   export KONNECT_TOKEN=...   # Konnect PAT (never stored)
#   export GITHUB_TOKEN=...    # fine-grained, read-only Contents on the repo
#   scripts/bootstrap.sh
#
# Steps (each asks before cluster-wide changes; ASSUME_YES=1 to skip prompts):
#   1. checks: logged in, cluster-admin, Gateway API CRDs present (managed by OpenShift)
#   2. namespaces (+ leg label)
#   3. OpenShift GitOps operator, and cluster-admin for its application controller
#   4. Secrets (scripts/create-secrets.sh) and Konnect link per leg (scripts/konnect-setup.sh)
#   5. the ArgoCD root application
source "$(dirname "$0")/lib.sh"
need oc jq openssl curl

log "1/5 checks"
oc whoami >/dev/null 2>&1 || die "not logged in: oc login -u kubeadmin https://api.crc.testing:6443"
oc auth can-i '*' '*' --all-namespaces >/dev/null 2>&1 || die "cluster-admin needed (log in as kubeadmin)"
oc version 2>/dev/null | sed 's/^/    /'
for crd in gatewayclasses gateways httproutes; do
  oc get crd "${crd}.gateway.networking.k8s.io" >/dev/null 2>&1 \
    || die "Gateway API CRD ${crd} missing. OpenShift 4.19+ installs them; older clusters need them installed by an admin."
done
log "    Gateway API CRDs: $(oc get crd httproutes.gateway.networking.k8s.io -o jsonpath='{.spec.versions[*].name}')"

log "2/5 namespaces"
for ns in $(legs); do
  oc get ns "$ns" >/dev/null 2>&1 || oc create ns "$ns" >/dev/null
  oc label ns "$ns" kong-poc/role=leg --overwrite >/dev/null
done
for ns in gw-shared idp blocking gslb-sim; do
  oc get ns "$ns" >/dev/null 2>&1 || oc create ns "$ns" >/dev/null
done
log "    $(legs | tr '\n' ' ')gw-shared idp blocking gslb-sim"

log "3/5 OpenShift GitOps"
if ! oc get crd applicationsets.argoproj.io >/dev/null 2>&1; then
  confirm "Install the OpenShift GitOps operator (cluster-wide)?" || die "aborted"
  oc apply -f - <<'YAML'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: latest
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
YAML
  log "    waiting for the operator and the default ArgoCD instance (a few minutes)..."
  for i in $(seq 1 90); do
    oc get deploy openshift-gitops-server -n openshift-gitops >/dev/null 2>&1 && break; sleep 10
  done
  oc rollout status deploy/openshift-gitops-server -n openshift-gitops --timeout=10m
fi
if ! oc get clusterrolebinding kong-poc-argocd-admin >/dev/null 2>&1; then
  confirm "Grant cluster-admin to the ArgoCD application controller (needed for GatewayClass, KongClusterPlugin, CRDs)?" || die "aborted"
  oc create clusterrolebinding kong-poc-argocd-admin --clusterrole=cluster-admin \
    --serviceaccount=openshift-gitops:openshift-gitops-argocd-application-controller >/dev/null
fi

log "4/5 secrets and Konnect"
"$REPO_ROOT/scripts/create-secrets.sh"
if [[ -n "${KONNECT_TOKEN:-}" ]]; then
  for leg in $(legs); do "$REPO_ROOT/scripts/konnect-setup.sh" "$leg"; done
  if ! git -C "$REPO_ROOT" diff --quiet -- charts/kong-values; then
    warn "charts/kong-values/values-<leg>.yaml changed (Konnect IDs). Commit and push them before ArgoCD syncs Kong:"
    warn "  git add charts/kong-values && git commit -m 'Konnect control plane IDs' && git push"
  fi
else
  warn "KONNECT_TOKEN not set: skipped Konnect. Kong will run without Enterprise plugins until it is done."
fi

log "5/5 ArgoCD root application"
oc apply -f "$REPO_ROOT/argocd/root.yaml" >/dev/null
log "done. Watch: oc get applications -n openshift-gitops -w"
log "ArgoCD UI: https://$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}')"
