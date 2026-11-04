#!/usr/bin/env bash
# Configures and starts OpenShift Local (CRC) for this POC.
#   scripts/crc-setup.sh small   # default: fits a 32 GB / 8-core workstation
#   scripts/crc-setup.sh full    # 48 GB+ / 12+ cores
# Needs: crc installed, and the pull secret from https://console.redhat.com/openshift/create/local
#        saved as ~/.crc/pull-secret.txt (or PULL_SECRET_FILE=...).
set -euo pipefail
profile="${1:-small}"
PULL_SECRET_FILE="${PULL_SECRET_FILE:-$HOME/.crc/pull-secret.txt}"

case "$profile" in
  small) cpus=6;  mem_mib=18432; disk_gib=80 ;;   # VM: 6 vCPU, 18 GiB
  full)  cpus=10; mem_mib=28672; disk_gib=100 ;;  # VM: 10 vCPU, 28 GiB
  *) echo "usage: $0 small|full" >&2; exit 1 ;;
esac

command -v crc >/dev/null || { echo "crc not installed: https://developers.redhat.com/products/openshift-local/overview" >&2; exit 1; }
[[ -f "$PULL_SECRET_FILE" ]] || { echo "pull secret missing: $PULL_SECRET_FILE" >&2; exit 1; }

crc config set preset openshift
crc config set cpus "$cpus"
crc config set memory "$mem_mib"
crc config set disk-size "$disk_gib"
crc config set pull-secret-file "$PULL_SECRET_FILE"
crc config set enable-cluster-monitoring false   # saves ~4 GiB; Prometheus scrape is shown manually
crc config set consent-telemetry no
crc setup
crc start
eval "$(crc oc-env)"
echo
crc console --credentials
echo "Log in with:  oc login -u kubeadmin https://api.crc.testing:6443"
