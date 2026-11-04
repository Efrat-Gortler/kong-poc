#!/usr/bin/env bash
# Shared helpers for the scripts in this folder. Source it, don't run it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPS_DOMAIN="${APPS_DOMAIN:-apps-crc.testing}"
KEYCLOAK_URL="${KEYCLOAK_URL:-https://keycloak-idp.${APPS_DOMAIN}}"
GSLB_URL="${GSLB_URL:-https://gslb-gslb-sim.${APPS_DOMAIN}}"
GSLB_CONTROL_URL="${GSLB_CONTROL_URL:-https://gslb-control-gslb-sim.${APPS_DOMAIN}}"
BLOCKING_URL="${BLOCKING_URL:-https://blocking-blocking.${APPS_DOMAIN}}"
REALM="${REALM:-corp}"
# CRC routes use a self-signed router certificate.
CURL=(curl -sS --fail-with-body -k)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

need() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing command: $c"; done; }

# Legs = files in environments/ (leg1, leg2, ...)
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
