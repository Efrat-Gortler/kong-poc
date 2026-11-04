#!/usr/bin/env bash
# Points every ArgoCD definition and the BuildConfig at a different Git URL.
#   scripts/set-repo-url.sh https://github.com/<owner>/kong-poc.git
source "$(dirname "$0")/lib.sh"
new="${1:?usage: $0 <git url>}"
old="https://github.com/khibye/kong-poc.git"
grep -rl --include='*.yaml' "$old" "$REPO_ROOT/argocd" "$REPO_ROOT/charts" | while read -r f; do
  sed -i.bak "s#$old#$new#g" "$f" && rm -f "$f.bak"; log "updated ${f#$REPO_ROOT/}"
done
