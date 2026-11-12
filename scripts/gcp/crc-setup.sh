#!/usr/bin/env bash
# Runs ON the GCP machine (CentOS Stream 9), called by scripts/gcp/vm.sh setup.
# Installs OpenShift Local, starts it, and publishes it on the machine's external IP, so a
# browser with hosts entries (scripts/windows/hosts-crc.cmd) reaches the console and the POC routes.
# CRC runs in its default "user" network mode: the crc daemon itself publishes 80/443 on all
# interfaces and 6443 on 127.0.0.1 only, so HAProxy only adds <host IP>:6443 -> 127.0.0.1:6443.
# The crc daemon is a systemd *user* service: lingering keeps it (and the VM's network) alive after
# SSH sessions end, and a user unit runs `crc start` at boot / `crc stop` at shutdown.
# Re-runnable: every step is idempotent.
set -euo pipefail
CRC_VERSION=2.63.0
# okd: no Red Hat account / pull secret needed (default). openshift: needs ~/.crc-pull-secret.txt
PRESET="${PRESET:-okd}"
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
# crc start prints the kubeadmin password: keep it out of logs and the journal
hide_password() { sed -E 's/^([[:space:]]*Password:).*/\1 (hidden - crc console --credentials)/'; }
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

log "3/6 configure: preset $PRESET, 7 vCPU / 26 GiB for OpenShift, the rest for the host"
crc config set consent-telemetry no >/dev/null
crc config set preset "$PRESET" >/dev/null
crc config set cpus 7 >/dev/null
crc config set memory 26624 >/dev/null
crc config set disk-size 120 >/dev/null
crc config set enable-cluster-monitoring false >/dev/null
if [[ "$PRESET" == openshift ]]; then
  [[ -f "$HOME/.crc-pull-secret.txt" ]] || die "preset openshift needs the Red Hat pull secret (~/.crc-pull-secret.txt)"
  crc config set pull-secret-file "$HOME/.crc-pull-secret.txt" >/dev/null
fi

log "4/6 crc setup + start (15-25 minutes, mostly waiting)"
crc setup
# without lingering, systemd kills the crc daemon when the last SSH session ends and the CRC VM loses its network
sudo loginctl enable-linger "$USER"
crc start 2>&1 | hide_password

log "5/6 publish the API: HAProxy <host IP>:6443 -> 127.0.0.1:6443 (80/443: crc daemon); autostart"
HOST_IP="$(ip -4 -o route get 1.1.1.1 | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')"
[[ -n "$HOST_IP" ]] || die "cannot find the host IP"
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
  bind $HOST_IP:6443
  default_backend api
backend api
  server crc 127.0.0.1:6443
CFG
# HAProxy may start before the NIC has its address at boot
echo 'net.ipv4.ip_nonlocal_bind = 1' | sudo tee /etc/sysctl.d/90-haproxy-nonlocal-bind.conf >/dev/null
sudo sysctl -q -p /etc/sysctl.d/90-haproxy-nonlocal-bind.conf
sudo setsebool -P haproxy_connect_any=1
sudo systemctl enable haproxy >/dev/null 2>&1
sudo systemctl restart haproxy
if systemctl is-active -q firewalld; then
  sudo firewall-cmd -q --permanent --add-port={80,443,6443}/tcp && sudo firewall-cmd -q --reload
fi
# OpenShift comes back by itself after the nightly stop (vm.sh start)
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/crc-autostart.service <<'UNIT'
[Unit]
Description=Start OpenShift Local at boot, stop it cleanly at shutdown
After=crc-daemon.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=30min
TimeoutStopSec=150
ExecStartPre=/bin/bash -c 'for i in $$(seq 60); do virsh -c qemu:///system version >/dev/null 2>&1 && exit 0; sleep 5; done; exit 1'
ExecStart=/bin/bash -o pipefail -c '/usr/local/bin/crc start 2>&1 | sed -E "s/^([[:space:]]*Password:).*/\\1 (hidden)/"'
ExecStop=/usr/local/bin/crc stop

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable crc-autostart.service >/dev/null 2>&1

log "6/6 tools for the POC scripts (oc, helm, python venv, gh)"
eval "$(crc oc-env)"
grep -q 'crc oc-env' ~/.bashrc || echo 'eval "$(crc oc-env)"' >> ~/.bashrc
# `crc stop` (at shutdown) removes the crc-admin context from ~/.kube/config, and `crc start` at boot
# often cannot re-add it (OAuth not up yet; its token also expires after 24 h). Fall back to CRC's own
# certificate-based admin kubeconfig; an explicit `oc login` (written to ~/.kube/config) still wins.
grep -q '.crc/machines/crc/kubeconfig' ~/.bashrc \
  || echo 'export KUBECONFIG="$HOME/.kube/config:$HOME/.crc/machines/crc/kubeconfig"' >> ~/.bashrc
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
