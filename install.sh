#!/usr/bin/env bash
set -euo pipefail

# === Config (edit these to your repo) ========================================
RAW_BASE_URL="${RAW_BASE_URL:-https://raw.githubusercontent.com/<your-user>/<your-repo>/main}"
PKG_DIR_URL="$RAW_BASE_URL/packages"

# Enable/disable “bundles” via env or flags:
#   BUNDLES="base,desktop,server,dev"
BUNDLES="${BUNDLES:-base}"

# Optional installers (true/false or 1/0)
WITH_DOCKER="${WITH_DOCKER:-0}"
WITH_TAILSCALE="${WITH_TAILSCALE:-0}"

# =============================================================================

log() { printf "\033[1;32m[+] %s\033[0m\n" "$*"; }
warn(){ printf "\033[1;33m[!] %s\033[0m\n" "$*"; }
err() { printf "\033[1;31m[✗] %s\033[0m\n" "$*" >&2; }

need_sudo() {
  if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      sudo -v || true
      SUDO="sudo"
    else
      err "This script needs root or sudo. Re-run with sudo."
      exit 1
    fi
  else
    SUDO=""
  fi
}

detect_distro() {
  . /etc/os-release
  DIST_ID="${ID:-ubuntu}"
  DIST_VER="${VERSION_CODENAME:-}"
  log "Detected: $PRETTY_NAME"
}

refresh_apt() {
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get update -y
  $SUDO apt-get install -y --no-install-recommends apt-transport-https ca-certificates gnupg lsb-release curl wget
}

fetch_pkg_list() {
  local list_name="$1"
  curl -fsSL "$PKG_DIR_URL/${list_name}.txt" | sed -e 's/#.*$//' -e '/^\s*$/d'
}

install_apt_packages() {
  local pkgs=("$@")
  if ((${#pkgs[@]})); then
    log "Installing APT packages: ${pkgs[*]}"
    $SUDO apt-get install -y "${pkgs[@]}"
  else
    warn "No packages to install in this step."
  fi
}

install_tailscale() {
  # Official one-liner from Tailscale team:
  curl -fsSL https://tailscale.com/install.sh | $SUDO sh
}

install_docker() {
  # Docker’s supported install for Debian/Ubuntu
  # Ref: https://docs.docker.com/engine/install/
  local arch
  arch="$(dpkg --print-architecture)"
  $SUDO apt-get install -y ca-certificates curl
  $SUDO install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/${DIST_ID}/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DIST_ID} \
    ${DIST_VER} stable" | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
  $SUDO apt-get update -y
  $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  if id -u "$SUDO_USER" >/dev/null 2>&1; then
    $SUDO usermod -aG docker "$SUDO_USER" || true
    log "Added $SUDO_USER to docker group (log out/in to take effect)."
  fi
}

parse_flags() {
  # Allow flags like: --bundles base,desktop --with-docker --with-tailscale
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bundles)
        BUNDLES="$2"; shift 2;;
      --with-docker)
        WITH_DOCKER=1; shift;;
      --with-tailscale)
        WITH_TAILSCALE=1; shift;;
      *)
        warn "Ignoring unknown arg: $1"; shift;;
    esac
  done
}

main() {
  parse_flags "$@"
  need_sudo
  detect_distro
  refresh_apt

  # Merge packages from selected bundles
  IFS=',' read -r -a bundle_arr <<< "$BUNDLES"
  declare -a to_install=()
  for b in "${bundle_arr[@]}"; do
    log "Loading package list: $b"
    mapfile -t pkgs < <(fetch_pkg_list "$b")
    to_install+=("${pkgs[@]}")
  done

  # Deduplicate
  if ((${#to_install[@]})); then
    mapfile -t to_install < <(printf "%s\n" "${to_install[@]}" | awk 'NF' | sort -u)
  fi

  install_apt_packages "${to_install[@]}"

  # Optional installers
  if [[ "$WITH_TAILSCALE" == "1" || "$WITH_TAILSCALE" == "true" ]]; then
    log "Installing Tailscale..."
    install_tailscale
  fi
  if [[ "$WITH_DOCKER" == "1" || "$WITH_DOCKER" == "true" ]]; then
    log "Installing Docker Engine & Compose plugin..."
    install_docker
  fi

  $SUDO apt-get autoremove -y
  log "All done! You can edit package lists in GitHub and re-run any time."
}

main "$@"

