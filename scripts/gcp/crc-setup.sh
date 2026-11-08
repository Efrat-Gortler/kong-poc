#!/usr/bin/env bash
# Runs ON the GCP machine (CentOS Stream 9), called by scripts/gcp/vm.sh setup.
# Installs OpenShift Local, starts it, and publishes it on the machine's external IP
# through HAProxy (80/443 -> routes, 6443 -> API), so a browser with hosts entries
# (scripts/windows/hosts-crc.cmd) reaches the console and the POC routes.
set -euo pipefail
CRC_VERSION=2.63.0
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
[[ -e /dev/kvm ]] || die "/dev/kvm missing: the VM was created without nested virtualization"

log "1/6 packages"
sudo dnf -y -q install libvirt NetworkManager haproxy policycoreutils-python-utils git jq tar xz python3 python3-pip >/dev/null
sudo systemctl enable --now libvirtd NetworkManager >/dev/null 2>&1 || true

log "2/6 crc $CRC_VERSION"
if [[ "$(crc version 2>/dev/null | awk '/CRC version/ {print $3}' | cut -d+ -f1)" != "$CRC_VERSION" ]]; then
  base="https://mirror.openshift.com/pub/openshift-v4/clients/crc/$CRC_VERSION"
  tmp="$(mktemp -d)"
  curl -fsSL "$base/crc-linux-amd64.tar.xz" -o "$tmp/crc.tar.xz"
  sum="$(curl -fsSL "$base/sha256sum.txt" | awk '/crc-linux-amd64.tar.xz$/ {print $1}')"
  echo "$sum  $tmp/crc.tar.xz" | sha256sum -c --quiet - || die "crc checksum mismatch"
  tar -xJf "$tmp/crc.tar.xz" -C "$tmp" && sudo install -m 0755 "$tmp"/crc-linux-*/crc /usr/local/bin/crc && rm -rf "$tmp"
fi
crc version

log "3/6 configure (7 vCPU / 26 GiB for OpenShift, the rest for the host)"
crc config set consent-telemetry no >/dev/null
crc config set preset openshift >/dev/null
crc config set cpus 7 >/dev/null
crc config set memory 26624 >/dev/null
crc config set disk-size 120 >/dev/null
crc config set enable-cluster-monitoring false >/dev/null
crc config set pull-secret-file "$HOME/.crc-pull-secret.txt" >/dev/null

log "4/6 crc setup + start (15-25 minutes, mostly waiting)"
crc setup
crc start

log "5/6 HAProxy: external IP -> OpenShift Local"
CRC_IP="$(crc ip)"
sudo tee /etc/haproxy/haproxy.cfg >/dev/null <<CFG
global
  log stdout format raw local0
  maxconn 4000
defaults
  mode tcp
  timeout connect 5s
  timeout client 1h
  timeout server 1h
frontend api
  bind 0.0.0.0:6443
  default_backend api
frontend https
  bind 0.0.0.0:443
  default_backend https
frontend http
  bind 0.0.0.0:80
  default_backend http
backend api
  server crc $CRC_IP:6443
backend https
  server crc $CRC_IP:443
backend http
  server crc $CRC_IP:80
CFG
sudo setsebool -P haproxy_connect_any=1
sudo systemctl enable --now haproxy >/dev/null 2>&1
sudo systemctl restart haproxy
if systemctl is-active -q firewalld; then
  sudo firewall-cmd -q --permanent --add-port={80,443,6443}/tcp && sudo firewall-cmd -q --reload
fi

log "6/6 tools for the POC scripts (oc, helm, python venv, gh)"
eval "$(crc oc-env)"
grep -q 'crc oc-env' ~/.bashrc || echo 'eval "$(crc oc-env)"' >> ~/.bashrc
if ! command -v helm >/dev/null; then
  v=v3.22.1; tmp="$(mktemp -d)"
  curl -fsSL "https://get.helm.sh/helm-$v-linux-amd64.tar.gz" -o "$tmp/h.tgz"
  echo "$(curl -fsSL "https://get.helm.sh/helm-$v-linux-amd64.tar.gz.sha256sum" | awk '{print $1}')  $tmp/h.tgz" | sha256sum -c --quiet -
  tar -xzf "$tmp/h.tgz" -C "$tmp" && sudo install -m 0755 "$tmp/linux-amd64/helm" /usr/local/bin/helm && rm -rf "$tmp"
fi
command -v gh >/dev/null || { sudo dnf -y -q install 'dnf-command(config-manager)' >/dev/null; \
  sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo >/dev/null; sudo dnf -y -q install gh >/dev/null; }
[[ -d ~/.venv ]] || python3 -m venv ~/.venv
~/.venv/bin/pip install -q -r ~/kong-poc/tests/acceptance/requirements.txt

echo
crc status
log "OpenShift Local is up. Console: https://console-openshift-console.apps-crc.testing"
log "kubeadmin password: crc console --credentials   (on this machine; don't paste it into chats)"
