#!/usr/bin/env bash
# One-time tool install inside Ubuntu 24.04 on WSL2 (laptop path). Run as your Linux user:
#   bash scripts/wsl/setup-tools.sh            # asks for your Linux password (sudo)
# Installs: Docker Engine (not Docker Desktop), kubectl, k3d, helm, gh, jq, python venv,
# and optionally k6 (WITH_K6=1). Pinned versions, checksums verified. Safe to re-run.
set -euo pipefail
KUBECTL_VERSION=v1.35.10
K3D_VERSION=v5.8.3
HELM_VERSION=v3.22.1
ARCH=amd64
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -r)" == *microsoft* ]] || log "not WSL? continuing anyway ($(uname -r))"
[[ $EUID -ne 0 ]] || die "run as your normal user, not root (the script uses sudo where needed)"
[[ "$(ps -p 1 -o comm=)" == systemd ]] || {
  printf '[boot]\nsystemd=true\n' | sudo tee /etc/wsl.conf >/dev/null
  die "systemd was off. Enabled it in /etc/wsl.conf - in Windows PowerShell run: wsl --shutdown ; then open Ubuntu again and re-run this script"
}

log "1/6 base packages"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl gnupg jq git openssl \
  python3-venv python3-pip unzip >/dev/null

log "2/6 Docker Engine (docker-ce from download.docker.com)"
if ! command -v docker >/dev/null; then
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin >/dev/null
fi
sudo systemctl enable --now docker >/dev/null
id -nG | grep -qw docker || { sudo usermod -aG docker "$USER"; NEED_RELOGIN=1; }

fetch_verified() { # url sha256 dest
  local tmp; tmp="$(mktemp)"
  curl -fsSL "$1" -o "$tmp"
  echo "$2  $tmp" | sha256sum -c --quiet - || die "checksum mismatch for $1"
  sudo install -m 0755 "$tmp" "$3"; rm -f "$tmp"
}

log "3/6 kubectl $KUBECTL_VERSION"
if [[ "$(kubectl version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion)" != "$KUBECTL_VERSION" ]]; then
  sum="$(curl -fsSL "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH/kubectl.sha256")"
  fetch_verified "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH/kubectl" "$sum" /usr/local/bin/kubectl
fi

log "4/6 k3d $K3D_VERSION"
if [[ "$(k3d version 2>/dev/null | awk '/k3d version/ {print $3}')" != "$K3D_VERSION" ]]; then
  sum="$(curl -fsSL "https://github.com/k3d-io/k3d/releases/download/$K3D_VERSION/checksums.txt" | awk "/k3d-linux-$ARCH\$/ {print \$1}")"
  [[ -n "$sum" ]] || die "no checksum for k3d-linux-$ARCH"
  fetch_verified "https://github.com/k3d-io/k3d/releases/download/$K3D_VERSION/k3d-linux-$ARCH" "$sum" /usr/local/bin/k3d
fi

log "5/6 helm $HELM_VERSION"
if [[ "$(helm version --template '{{.Version}}' 2>/dev/null)" != "$HELM_VERSION" ]]; then
  tmp="$(mktemp -d)"
  curl -fsSL "https://get.helm.sh/helm-$HELM_VERSION-linux-$ARCH.tar.gz" -o "$tmp/helm.tgz"
  echo "$(curl -fsSL "https://get.helm.sh/helm-$HELM_VERSION-linux-$ARCH.tar.gz.sha256sum" | awk '{print $1}')  $tmp/helm.tgz" | sha256sum -c --quiet - \
    || die "helm checksum mismatch"
  tar -xzf "$tmp/helm.tgz" -C "$tmp" && sudo install -m 0755 "$tmp/linux-$ARCH/helm" /usr/local/bin/helm && rm -rf "$tmp"
fi

log "6/6 GitHub CLI (for pushing from WSL)"
if ! command -v gh >/dev/null; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli.gpg >/dev/null
  echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gh >/dev/null
fi

if [[ "${WITH_K6:-0}" == "1" ]] && ! command -v k6 >/dev/null; then
  log "k6 (load test)"
  curl -fsSL https://dl.k6.io/key.gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/k6.gpg
  echo "deb [signed-by=/etc/apt/keyrings/k6.gpg] https://dl.k6.io/deb stable main" | sudo tee /etc/apt/sources.list.d/k6.list >/dev/null
  sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq k6 >/dev/null
fi

echo
docker --version; kubectl version --client 2>/dev/null | head -1; k3d version | head -1; helm version --short; gh --version | head -1
free -h | head -2
if [[ "${NEED_RELOGIN:-0}" == "1" ]]; then
  echo; echo "You were added to the 'docker' group: close this Ubuntu window and open it again before the next step."
fi
