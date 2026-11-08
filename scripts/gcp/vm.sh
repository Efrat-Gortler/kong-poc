#!/usr/bin/env bash
# Run in Google Cloud Shell: everything on the POC machine goes through here.
#   bash scripts/gcp/vm.sh setup        # copies the repo + pull secret, installs OpenShift Local (30-40 min)
#   bash scripts/gcp/vm.sh ssh          # shell on the machine (repo in ~/kong-poc)
#   bash scripts/gcp/vm.sh start|stop   # start/stop the VM (OpenShift starts again by itself)
#   bash scripts/gcp/vm.sh ip           # external IP (for scripts/windows/hosts-crc.cmd)
#   bash scripts/gcp/vm.sh run <cmd>    # one command in ~/kong-poc on the machine
# The pull secret is read from ~/pull-secret.txt in Cloud Shell (upload it there first).
set -euo pipefail
NAME="${NAME:-kong-poc-crc}"
REGION="${REGION:-europe-west1}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ssh_vm() { gcloud compute ssh "$NAME" --tunnel-through-iap --quiet "$@"; }

case "${1:-}" in
  setup)
    [[ -f "$HOME/pull-secret.txt" ]] || { echo "upload the Red Hat pull secret to Cloud Shell first (it lands in ~/pull-secret.txt)"; exit 1; }
    git -C "$REPO_ROOT" bundle create /tmp/kong-poc.bundle --all >/dev/null 2>&1
    gcloud compute scp --tunnel-through-iap --quiet /tmp/kong-poc.bundle "$HOME/pull-secret.txt" "$NAME":/tmp/
    ssh_vm --command 'set -e
      [[ -d ~/kong-poc ]] || git clone -q /tmp/kong-poc.bundle ~/kong-poc
      git -C ~/kong-poc remote set-url origin "'"$(git -C "$REPO_ROOT" remote get-url origin)"'"
      install -m 600 /tmp/pull-secret.txt ~/.crc-pull-secret.txt && rm -f /tmp/pull-secret.txt
      bash ~/kong-poc/scripts/gcp/crc-setup.sh' ;;
  ssh)   ssh_vm ;;
  run)   shift; ssh_vm --command "cd ~/kong-poc && $*" ;;
  start) gcloud compute instances start "$NAME" && echo "OpenShift needs ~5 more minutes: bash scripts/gcp/vm.sh run 'crc status'" ;;
  stop)  gcloud compute instances stop "$NAME" ;;
  ip)    gcloud compute addresses describe "$NAME-ip" --region "$REGION" --format='value(address)' ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
