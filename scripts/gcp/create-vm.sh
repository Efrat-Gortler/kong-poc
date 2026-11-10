#!/usr/bin/env bash
# Run in Google Cloud Shell. Creates the POC machine for OpenShift Local (CRC):
#   n2-standard-8 (8 vCPU, 32 GB), nested virtualization, CentOS Stream 9, 150 GB disk,
#   static external IP, nightly auto-stop at 22:00 Asia/Jerusalem.
# Network: SSH only through IAP (gcloud compute ssh --tunnel-through-iap);
#          80/443/6443 (OpenShift console, routes, API) only from ALLOW_IP.
#
#   ALLOW_IP=<your home IP or range, e.g. 188.64.206.0/24> bash scripts/gcp/create-vm.sh
# A home IP that changes: allow its /24 range, or re-run with the new IP (only the firewall is updated).
# Safe to re-run: existing pieces are kept.
set -euo pipefail
PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-europe-west1}"
ZONE="${ZONE:-europe-west1-b}"
NAME="${NAME:-kong-poc-crc}"
MACHINE="${MACHINE:-n2-standard-8}"
: "${ALLOW_IP:?set ALLOW_IP to your public IP or range (https://api.ipify.org)}"
[[ "$ALLOW_IP" == */* ]] || ALLOW_IP="$ALLOW_IP/32"
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
[[ -n "$PROJECT" ]] || die "no project: gcloud config set project <PROJECT_ID>"
gcloud config set project "$PROJECT" >/dev/null
gcloud config set compute/zone "$ZONE" >/dev/null

log "1/6 APIs (project $PROJECT)"
gcloud services enable compute.googleapis.com iap.googleapis.com

log "2/6 quota in $REGION"
q="$(gcloud compute regions describe "$REGION" --format=json)"
for m in N2_CPUS CPUS; do
  read -r limit usage < <(jq -r --arg m "$m" '.quotas[] | select(.metric==$m) | "\(.limit|floor) \(.usage|floor)"' <<<"$q")
  echo "    $m: $usage used of $limit"
  (( limit - usage >= 8 )) || die "$m quota too low for $MACHINE (needs 8 free). Ask for an increase or use REGION=... "
done

log "3/6 static IP and firewall"
gcloud compute addresses describe "$NAME-ip" --region "$REGION" >/dev/null 2>&1 \
  || gcloud compute addresses create "$NAME-ip" --region "$REGION"
IP="$(gcloud compute addresses describe "$NAME-ip" --region "$REGION" --format='value(address)')"
gcloud compute firewall-rules describe "$NAME-iap-ssh" >/dev/null 2>&1 \
  || gcloud compute firewall-rules create "$NAME-iap-ssh" --network default --direction INGRESS \
       --allow tcp:22 --source-ranges 35.235.240.0/20 --target-tags "$NAME"
if gcloud compute firewall-rules describe "$NAME-web" >/dev/null 2>&1; then
  gcloud compute firewall-rules update "$NAME-web" --source-ranges "$ALLOW_IP"
else
  gcloud compute firewall-rules create "$NAME-web" --network default --direction INGRESS \
    --allow tcp:80,tcp:443,tcp:6443 --source-ranges "$ALLOW_IP" --target-tags "$NAME"
fi

log "4/6 nightly stop at 22:00 Asia/Jerusalem"
PN="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"
# the Compute Engine service agent stops the VM on schedule
gcloud projects add-iam-policy-binding "$PROJECT" --condition=None --quiet \
  --member "serviceAccount:service-$PN@compute-system.iam.gserviceaccount.com" \
  --role roles/compute.instanceAdmin.v1 >/dev/null
gcloud compute resource-policies describe "$NAME-nightly" --region "$REGION" >/dev/null 2>&1 \
  || gcloud compute resource-policies create instance-schedule "$NAME-nightly" --region "$REGION" \
       --vm-stop-schedule="0 22 * * *" --timezone=Asia/Jerusalem

log "5/6 VM $NAME ($MACHINE, nested virtualization)"
if ! gcloud compute instances describe "$NAME" >/dev/null 2>&1; then
  gcloud compute instances create "$NAME" --machine-type "$MACHINE" \
    --enable-nested-virtualization --min-cpu-platform "Intel Cascade Lake" \
    --image-family centos-stream-9 --image-project centos-cloud \
    --boot-disk-size 150GB --boot-disk-type pd-balanced \
    --address "$IP" --tags "$NAME" \
    --resource-policies "$NAME-nightly" \
    --metadata enable-oslogin=TRUE
fi

log "6/6 waiting for SSH"
for i in $(seq 1 30); do
  gcloud compute ssh "$NAME" --tunnel-through-iap --quiet --command 'echo ssh-ok' 2>/dev/null | grep -q ssh-ok && break
  sleep 10
done
gcloud compute ssh "$NAME" --tunnel-through-iap --quiet --command \
  'echo "kvm: $(ls /dev/kvm 2>/dev/null || echo MISSING)"; nproc; free -g | head -2; df -h / | tail -1'
echo
log "VM ready. External IP: $IP"
log "next: bash scripts/gcp/vm.sh setup"
