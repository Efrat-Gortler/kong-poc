#!/usr/bin/env bash
# Creates every Secret the POC needs, with random values. Nothing secret is ever
# written to Git or to disk. Existing Secrets are kept (safe to re-run).
#
# Needs: GITHUB_TOKEN (fine-grained, read-only "Contents" on the kong-poc repo)
#        for ArgoCD and for the in-cluster build of the blocking service.
source "$(dirname "$0")/lib.sh"
need oc openssl

ensure_secret() { # ns name -- args for "oc create secret generic"
  local ns=$1 name=$2; shift 2
  if oc get secret "$name" -n "$ns" >/dev/null 2>&1; then
    log "keep   $ns/$name"
  else
    oc create secret generic "$name" -n "$ns" "$@" >/dev/null
    log "create $ns/$name"
  fi
}

copy_secret() { # from_ns name to_ns
  if oc get secret "$2" -n "$3" >/dev/null 2>&1; then log "keep   $3/$2"; return; fi
  oc get secret "$2" -n "$1" -o json \
    | python3 -c 'import json,sys; s=json.load(sys.stdin); print(json.dumps({"apiVersion":"v1","kind":"Secret","metadata":{"name":s["metadata"]["name"]},"type":s.get("type","Opaque"),"data":s["data"]}))' \
    | oc apply -n "$3" -f - >/dev/null
  log "copy   $1/$2 -> $3"
}

# Shared Redis password: in gw-shared, copied to each leg (plugins read it via configPatches)
ensure_secret gw-shared redis-auth --from-literal=password="$(random_secret)"
for leg in $(legs); do copy_secret gw-shared redis-auth "$leg"; done

# Gateway -> blocking service reader key (Lua plugin header, OPA bearer token)
ensure_secret blocking blocklist-reader --from-literal=api-key="$(random_secret)"
for leg in $(legs); do copy_secret blocking blocklist-reader "$leg"; done

# Blocking service database
ensure_secret blocking blocking-db --from-literal=username=blocking --from-literal=password="$(random_secret)"

# Keycloak admin + test-user / test-client credentials (resolved into the realm import)
ensure_secret idp keycloak-admin --from-literal=username=admin --from-literal=password="$(random_secret)"
ensure_secret idp idp-test-credentials \
  --from-literal=KC_TEST_USER_PASSWORD="$(random_secret)" \
  --from-literal=KC_SYSTEM_CLIENT_SECRET="$(random_secret)"

# GitHub access for ArgoCD and for the BuildConfig (private repo)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  REPO_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo https://github.com/khibye/kong-poc.git)"
  REPO_URL="${REPO_URL%.git}.git"
  if ! oc get secret repo-kong-poc -n openshift-gitops >/dev/null 2>&1; then
    oc create secret generic repo-kong-poc -n openshift-gitops \
      --from-literal=type=git --from-literal=url="$REPO_URL" \
      --from-literal=username=git --from-literal=password="$GITHUB_TOKEN" >/dev/null
    oc label secret repo-kong-poc -n openshift-gitops argocd.argoproj.io/secret-type=repository >/dev/null
    log "create openshift-gitops/repo-kong-poc"
  else
    log "keep   openshift-gitops/repo-kong-poc"
  fi
  if ! oc get secret github-source -n blocking >/dev/null 2>&1; then
    oc create secret generic github-source -n blocking --type=kubernetes.io/basic-auth \
      --from-literal=username=git --from-literal=password="$GITHUB_TOKEN" >/dev/null
    oc annotate secret github-source -n blocking 'build.openshift.io/source-secret-match-uri-1=https://github.com/*' >/dev/null
    log "create blocking/github-source"
  else
    log "keep   blocking/github-source"
  fi
else
  warn "GITHUB_TOKEN not set: skipped ArgoCD repo secret and build source secret (fine if the repo is public)"
fi

log "done. Read a value with: oc get secret <name> -n <ns> -o jsonpath='{.data.<key>}' | base64 -d"
