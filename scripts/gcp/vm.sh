#!/usr/bin/env bash
# Run in Google Cloud Shell: everything on the POC machine goes through here.
#   bash scripts/gcp/vm.sh setup        # copies the repo, installs OpenShift Local / OKD (30-40 min)
#   bash scripts/gcp/vm.sh logs         # follow / show the installation log (safe to reconnect)
#   bash scripts/gcp/vm.sh ssh          # shell on the machine (repo in ~/kong-poc)
#   bash scripts/gcp/vm.sh start|stop   # start/stop the VM (OpenShift starts again by itself)
#   bash scripts/gcp/vm.sh ip           # external IP (for scripts/windows/hosts-crc.cmd)
#   bash scripts/gcp/vm.sh run <cmd>    # one command in ~/kong-poc on the machine
# Default preset: okd (no Red Hat account). PRESET=openshift also needs ~/pull-secret.txt in Cloud Shell.
set -euo pipefail
NAME="${NAME:-kong-poc-crc}"
REGION="${REGION:-europe-west1}"
ZONE="${ZONE:-europe-west1-b}"   # explicit: a new Cloud Shell session may have no default zone
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ssh_vm() { gcloud compute ssh "$NAME" --zone "$ZONE" --tunnel-through-iap --quiet "$@"; }

case "${1:-}" in
  setup)
    PRESET="${PRESET:-okd}"
    files=(/tmp/kong-poc.bundle)
    if [[ "$PRESET" == openshift ]]; then
      [[ -f "$HOME/pull-secret.txt" ]] || { echo "PRESET=openshift: upload the Red Hat pull secret to Cloud Shell first (~/pull-secret.txt)"; exit 1; }
      files+=("$HOME/pull-secret.txt")
    fi
    git -C "$REPO_ROOT" bundle create /tmp/kong-poc.bundle --all >/dev/null 2>&1
    gcloud compute scp --zone "$ZONE" --tunnel-through-iap --quiet "${files[@]}" "$NAME":/tmp/
    ssh_vm --command 'set -e
      command -v git >/dev/null || sudo dnf -y -q install git >/dev/null   # not in the CentOS Stream image
      [[ -d ~/kong-poc ]] || git clone -q /tmp/kong-poc.bundle ~/kong-poc
      git -C ~/kong-poc remote set-url origin "'"$(git -C "$REPO_ROOT" remote get-url origin)"'"
      if [[ -f /tmp/pull-secret.txt ]]; then install -m 600 /tmp/pull-secret.txt ~/.crc-pull-secret.txt && rm -f /tmp/pull-secret.txt; fi
      # detached: keeps running on the VM if Cloud Shell disconnects; log in ~/crc-setup.log
      PRESET='"$PRESET"' setsid nohup bash ~/kong-poc/scripts/gcp/crc-setup.sh > ~/crc-setup.log 2>&1 < /dev/null &
      echo "installation started on the VM (pid $!)"'
    "$0" logs ;;
  logs)  # follow the installation log; Ctrl+C stops watching, not the installation
    ssh_vm --command 'p=$(pgrep -f crc-setup.sh | head -1); if [[ -n "$p" ]]; then tail -n +1 -f --pid="$p" ~/crc-setup.log; else cat ~/crc-setup.log 2>/dev/null || echo "no installation log yet"; fi' ;;
  ssh)   ssh_vm ;;
  run)   shift; ssh_vm --command "cd ~/kong-poc && $*" ;;
  start) gcloud compute instances start "$NAME" --zone "$ZONE" && echo "OpenShift needs ~5 more minutes: bash scripts/gcp/vm.sh run 'crc status'" ;;
  stop)  gcloud compute instances stop "$NAME" --zone "$ZONE" ;;
  ip)    gcloud compute addresses describe "$NAME-ip" --region "$REGION" --format='value(address)' ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac
