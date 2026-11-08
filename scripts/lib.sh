#!/usr/bin/env bash
# Shared helpers for the scripts in this folder. Source it, don't run it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- platform (cluster/platform.yaml) -> external hosts and scheme
yaml_value() { # file key  (top-level or under "global:", simple scalars only)
  awk -v k="$2" '$1 == k":" {print $2; exit}' "$1" | tr -d '"'"'"
}
POC_PLATFORM="${POC_PLATFORM:-$(yaml_value "$REPO_ROOT/cluster/platform.yaml" platform)}"
_cluster_values="$REPO_ROOT/cluster/values-${POC_PLATFORM}.yaml"
APPS_DOMAIN="${APPS_DOMAIN:-$(yaml_value "$_cluster_values" appsDomain)}"
SCHEME="${SCHEME:-$(yaml_value "$_cluster_values" ingressScheme)}"
KEYCLOAK_URL="${KEYCLOAK_URL:-${SCHEME}://keycloak-idp.${APPS_DOMAIN}}"
GSLB_URL="${GSLB_URL:-${SCHEME}://gslb-gslb-sim.${APPS_DOMAIN}}"
GSLB_CONTROL_URL="${GSLB_CONTROL_URL:-${SCHEME}://gslb-control-gslb-sim.${APPS_DOMAIN}}"
BLOCKING_URL="${BLOCKING_URL:-${SCHEME}://blocking-blocking.${APPS_DOMAIN}}"
REALM="${REALM:-corp}"
# OpenShift routes use a self-signed router certificate (CRC); -k is harmless on http.
CURL=(curl -sS --fail-with-body -k)

# `oc` everywhere in these scripts; on plain Kubernetes it is kubectl.
if ! command -v oc >/dev/null 2>&1; then
  oc() { kubectl "$@"; }
fi

# Optional: copy everything a script prints into a log file (e.g. a Windows folder
# Claude can read):  export POC_LOG_DIR=/mnt/c/Users/<you>/Desktop/<folder>/logs
if [[ -n "${POC_LOG_DIR:-}" && -z "${_POC_LOGGING:-}" ]]; then
  export _POC_LOGGING=1
  mkdir -p "$POC_LOG_DIR"
  exec > >(tee -a "$POC_LOG_DIR/$(basename "$0" .sh).log") 2>&1
  printf '\n===== %s  %s %s\n' "$(date -Is)" "$(basename "$0")" "$*"
fi

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

need() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing command: $c"; done; }

# Active legs = files directly in environments/ (parked legs live in environments/standby/)
legs() { for f in "$REPO_ROOT"/environments/*.yaml; do basename "$f" .yaml; done; }

# Ask before anything cluster-wide or destructive. ASSUME_YES=1 skips the prompt.
confirm() {
  [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
  read -r -p "$1 [y/N] " a
  [[ "$a" == "y" || "$a" == "Y" ]]
}

secret_value() { # ns name key
  oc get secret "$2" -n "$1" -o jsonpath="{.data.$3}" | base64 -d
}

random_secret() { openssl rand -base64 33 | tr -d '/+=\n' | cut -c1-32; }
