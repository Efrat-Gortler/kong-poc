#!/usr/bin/env bash
# Run in Google Cloud Shell: everything on the POC machine goes through here.
#   bash scripts/gcp/vm.sh setup        # copies the repo, installs OpenShift Local / OKD (30-40 min)
#   bash scripts/gcp/vm.sh ssh          # shell on the machine (repo in ~/kong-poc)
#   bash scripts/gcp/vm.sh start|stop   # start/stop the VM (OpenShift starts again by itself)
#   bash scripts/gcp/vm.sh ip           # external IP (for scripts/windows/hosts-crc.cmd)
#   bash scripts/gcp/vm.sh run <cmd>    # one command in ~/kong-poc on the machine
# Default preset: okd (no Red Hat account). PRESET=openshift also needs ~/pull-secret.txt in Cloud Shell.
set -euo pipefail
NAME="${NAME:-kong-poc-crc}"
REGION="${REGION:-europe-west1}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ssh_vm() { gcloud compute ssh "$NAME" --tunnel-through-iap --quiet "$@"; }

case "${1:-}" in
  setup)
    PRESET="${PRESET:-okd}"
    files=(/tmp/kong-poc.bundle)
    if [[ "$PRESET" == openshift ]]; then
      [[ -f "$HOME/pull-secret.txt" ]] || { echo "PRESET=openshift: upload the Red Hat pull secret to Cloud Shell first (~/pull-secret.txt)"; exit 1; }
      files+=("$HOME/pull-secret.txt")
    fi
    git -C "$REPO_ROOT" bundle create /tmp/kong-poc.bundle --all >/dev/null 2>&1
    gcloud compute scp --tunnel-through-iap --quiet "${files[@]}" "$NAME":/tmp/
    ssh_vm --command 'set -e
      [[ -d ~/kong-poc ]] || git clone -q /tmp/kong-poc.bundle ~/kong-poc
      git -C ~/kong-poc remote set-url origin "'"$(git -C "$REPO_ROOT" remote get-url origin)"'"
      if [[ -f /tmp/pull-secret.txt ]]; then install -m 600 /tmp/pull-secret.txt ~/.crc-pull-secret.txt && rm -f /tmp/pull-secret.txt; fi
      PRESET='"$PRESET"' bash ~/kong-poc/scripts/gcp/crc-setup.sh' ;;
  ssh)   ssh_vm ;;
  run)   shift; ssh_vm --command "cd ~/kong-poc && $*" ;;
  start) gcloud compute instances start "$NAME" && echo "OpenShift needs ~5 more minutes: bash scripts/gcp/vm.sh run 'crc status'" ;;
  stop)  gcloud compute instances stop "$NAME" ;;
  ip)    gcloud compute addresses describe "$NAME-ip" --region "$REGION" --format='value(address)' ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
