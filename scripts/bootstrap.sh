#!/usr/bin/env bash
# One-time bootstrap of an empty cluster. After this, everything comes from Git via ArgoCD.
#
#   export KONNECT_TOKEN=...   # Konnect PAT (never stored)
#   export GITHUB_TOKEN=...    # only if the repo is private: read-only Contents on the repo
#   scripts/bootstrap.sh
#
# Platform from cluster/platform.yaml (openshift | kubernetes). On kubernetes (k3d) run
# scripts/k3d/cluster.sh create first.
# Steps (each asks before cluster-wide changes; ASSUME_YES=1 to skip prompts):
#   1. checks: cluster-admin; OpenShift: Gateway API CRDs present (managed by the platform)
#   2. namespaces (+ leg label; Pod Security "restricted" warnings on kubernetes)
#   3. GitOps: OpenShift GitOps operator | minimal upstream Argo CD (cluster/kubernetes/argocd)
#   4. Secrets (scripts/create-secrets.sh) and Konnect link per leg (scripts/konnect-setup.sh)
#   5. the ArgoCD root application
source "$(dirname "$0")/lib.sh"
need oc jq openssl curl

log "1/5 checks (platform: $POC_PLATFORM)"
oc auth can-i '*' '*' --all-namespaces >/dev/null 2>&1 || die "cluster-admin needed (OpenShift: oc login -u kubeadmin ...; k3d: scripts/k3d/cluster.sh create)"
oc version 2>/dev/null | sed 's/^/    /'
if [[ "$POC_PLATFORM" == openshift ]]; then
  for crd in gatewayclasses gateways httproutes; do
    oc get crd "${crd}.gateway.networking.k8s.io" >/dev/null 2>&1 \
      || die "Gateway API CRD ${crd} missing. OpenShift 4.19+ installs them; older clusters need them installed by an admin."
  done
  log "    Gateway API CRDs: $(oc get crd httproutes.gateway.networking.k8s.io -o jsonpath='{.spec.versions[*].name}')"
else
  log "    Gateway API CRDs: installed by ArgoCD (app gateway-api-crds)"
fi

log "2/5 namespaces"
for ns in $(legs); do
  oc get ns "$ns" >/dev/null 2>&1 || oc create ns "$ns" >/dev/null
  oc label ns "$ns" kong-poc/role=leg --overwrite >/dev/null
done
for ns in gw-shared idp blocking gslb-sim; do
  oc get ns "$ns" >/dev/null 2>&1 || oc create ns "$ns" >/dev/null
done
if [[ "$POC_PLATFORM" != openshift ]]; then
  # closest thing to OpenShift's restricted-v2 SCC: report (not block) anything that
  # would not pass the "restricted" Pod Security Standard
  for ns in $(legs) gw-shared idp blocking gslb-sim; do
    oc label ns "$ns" pod-security.kubernetes.io/warn=restricted pod-security.kubernetes.io/audit=restricted --overwrite >/dev/null
  done
fi
log "    $(legs | tr '\n' ' ')gw-shared idp blocking gslb-sim"

if [[ "$POC_PLATFORM" != openshift ]]; then
  log "3/5 Argo CD (minimal core install, namespace openshift-gitops)"
  if ! oc get deploy argocd-repo-server -n openshift-gitops >/dev/null 2>&1; then
    confirm "Install Argo CD v3.5.7 (core: no UI) into this cluster?" || die "aborted"
  fi
  kubectl apply --server-side --force-conflicts -k "$REPO_ROOT/cluster/kubernetes/argocd" >/dev/null
  kubectl wait --for=condition=Established crd/applications.argoproj.io crd/applicationsets.argoproj.io --timeout=60s >/dev/null
  kubectl apply --server-side -n openshift-gitops -f "$REPO_ROOT/cluster/kubernetes/argocd/default-project.yaml" >/dev/null
  for d in argocd-repo-server argocd-applicationset-controller argocd-redis; do
    kubectl rollout status "deploy/$d" -n openshift-gitops --timeout=5m
  done
  kubectl rollout status statefulset/argocd-application-controller -n openshift-gitops --timeout=5m
fi
if [[ "$POC_PLATFORM" == openshift ]] && ! oc get crd applicationsets.argoproj.io >/dev/null 2>&1; then
  log "3/5 OpenShift GitOps"
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
if [[ "$POC_PLATFORM" == openshift ]] && ! oc get clusterrolebinding kong-poc-argocd-admin >/dev/null 2>&1; then
  confirm "Grant cluster-admin to the ArgoCD application controller (needed for GatewayClass, KongClusterPlugin, CRDs)?" || die "aborted"
  oc create clusterrolebinding kong-poc-argocd-admin --clusterrole=cluster-admin \
    --serviceaccount=openshift-gitops:openshift-gitops-argocd-application-controller >/dev/null
fi

log "4/5 secrets and Konnect"
"$REPO_ROOT/scripts/create-secrets.sh"
if [[ -n "${KONNECT_TOKEN:-}" ]]; then
  for leg in $(legs); do "$REPO_ROOT/scripts/konnect-setup.sh" "$leg"; done
  if ! git -C "$REPO_ROOT" diff --quiet -- charts/kong-values; then
    # ArgoCD must see the real control plane IDs before it installs Kong.
    git -C "$REPO_ROOT" --no-pager diff --stat -- charts/kong-values
    confirm "Commit and push the Konnect control plane IDs (not secret) now?" \
      || die "push them yourself, then re-run: git add charts/kong-values && git commit -m 'Konnect control plane IDs' && git push"
    git -C "$REPO_ROOT" add charts/kong-values
    git -C "$REPO_ROOT" commit -q -m "Konnect control plane IDs"
    git -C "$REPO_ROOT" push -q
  fi
  for leg in $(legs); do
    grep -q KONNECT_CP_ID_ "$REPO_ROOT/charts/kong-values/values-$leg.yaml" && die "$leg still has a KONNECT_CP_ID placeholder"
  done
else
  warn "KONNECT_TOKEN not set: skipped Konnect. Kong will run without Enterprise plugins until it is done."
fi

log "5/5 ArgoCD root application"
oc apply -f "$REPO_ROOT/argocd/root.yaml" >/dev/null
log "done. Watch: oc get applications -n openshift-gitops -w"
if [[ "$POC_PLATFORM" == openshift ]]; then
  log "ArgoCD UI: https://$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}')"
fi
