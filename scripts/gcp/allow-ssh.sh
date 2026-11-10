#!/usr/bin/env bash
# Run in Cloud Shell. Lets your own computer SSH straight to the POC machine (for
# VS Code Remote-SSH): opens port 22 from ALLOW_IP only and registers your PUBLIC key
# with OS Login. Prints the host/user/IP to put into VS Code.
#   ALLOW_IP=188.64.206.0/24 bash scripts/gcp/allow-ssh.sh "ssh-ed25519 AAAA... kong-poc"
set -euo pipefail
NAME="${NAME:-kong-poc-crc}"; REGION="${REGION:-europe-west1}"
KEY="${1:?usage: ALLOW_IP=<ip or range> $0 \"<contents of your .pub file>\"}"
: "${ALLOW_IP:?set ALLOW_IP to your public IP or range}"
[[ "$ALLOW_IP" == */* ]] || ALLOW_IP="$ALLOW_IP/32"
[[ "$KEY" == ssh-* ]] || { echo "that does not look like a PUBLIC key (it should start with ssh-ed25519 / ssh-rsa)"; exit 1; }
if gcloud compute firewall-rules describe "$NAME-ssh" >/dev/null 2>&1; then
  gcloud compute firewall-rules update "$NAME-ssh" --source-ranges "$ALLOW_IP"
else
  gcloud compute firewall-rules create "$NAME-ssh" --network default --direction INGRESS \
    --allow tcp:22 --source-ranges "$ALLOW_IP" --target-tags "$NAME"
fi
gcloud compute os-login ssh-keys add --key="$KEY" --ttl=0 >/dev/null
USER_NAME="$(gcloud compute os-login describe-profile --format='value(posixAccounts[0].username)')"
IP="$(gcloud compute addresses describe "$NAME-ip" --region "$REGION" --format='value(address)')"
cat <<OUT

Done. Add this to C:\\Users\\<you>\\.ssh\\config on your computer (VS Code: "Remote-SSH: Open SSH Configuration File"):

Host kong-poc
  HostName $IP
  User $USER_NAME
  IdentityFile ~/.ssh/gcp_kongpoc

OUT
