#!/usr/bin/env bash
set -euo pipefail

# === Config (edit these to your repo) ========================================
RAW_BASE_URL="${RAW_BASE_URL:-https://raw.githubusercontent.com/njinco/linins/main}"
PKG_DIR_URL="$RAW_BASE_URL/packages"

# Enable/disable “bundles” via env or flags:
#   BUNDLES="base,desktop,server,dev"
BUNDLES="${BUNDLES:-base}"

# Optional installers (true/false or 1/0)
WITH_DOCKER="${WITH_DOCKER:-0}"
WITH_TAILSCALE="${WITH_TAILSCALE:-0}"
DRY_RUN="${DRY_RUN:-0}"
STEP_MODE="${STEP_MODE:-0}"

# =============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

log() { printf "\033[1;32m[+] %s\033[0m\n" "$*"; }
warn(){ printf "\033[1;33m[!] %s\033[0m\n" "$*"; }
err() { printf "\033[1;31m[✗] %s\033[0m\n" "$*" >&2; }

step() {
  local msg="$1"
  STEP_NO=$((STEP_NO + 1))
  log "Step ${STEP_NO}: ${msg}"
  if [[ "$STEP_MODE" == "1" || "$STEP_MODE" == "true" ]]; then
    printf "Press Enter to continue, or 'q' to quit: "
    read -r step_ans
    if [[ "$step_ans" == "q" || "$step_ans" == "Q" ]]; then
      warn "Aborted by user."
      exit 0
    fi
  fi
}

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --bundles <list>     Comma-separated bundles to install (default: base)
  --with-docker        Install Docker Engine and Compose plugin
  --with-tailscale     Install Tailscale
  --list-bundles       List bundle files from local packages/ dir
  --print-packages     Print resolved package list and exit
  --validate-packages  Verify packages exist in APT cache before install
  --validate-only      Validate packages and exit without installing
  --dry-run            Print actions without making changes
  --step, --interactive  Prompt before each major step
  -V, --version        Show script version
  -h, --help           Show this help

Environment:
  BUNDLES              Same as --bundles
  WITH_DOCKER          1/0 or true/false
  WITH_TAILSCALE       1/0 or true/false
  DRY_RUN              1/0 or true/false
  STEP_MODE            1/0 or true/false
  RAW_BASE_URL         Override base URL for package lists
  VALIDATE_PACKAGES    1/0 or true/false
EOF
}

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
  case "$DIST_ID" in
    ubuntu|debian) ;;
    *)
      err "Unsupported distro: ${DIST_ID}. This script supports Debian/Ubuntu."
      exit 1
      ;;
  esac
}

detect_arch() {
  local arch_raw
  arch_raw="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "$arch_raw" in
    amd64|x86_64) ARCH="amd64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) ARCH="$arch_raw"; warn "Unknown architecture: $arch_raw" ;;
  esac
  log "Detected architecture: $ARCH"
}

list_bundles() {
  if [[ -d "${SCRIPT_DIR}/packages" ]]; then
    find "${SCRIPT_DIR}/packages" -maxdepth 1 -type f -name '*.txt' -printf '%f\n' | sed 's/\.txt$//'
  else
    err "Local packages/ directory not found. Try running from a clone."
    exit 1
  fi
}

show_version() {
  if command -v git >/dev/null 2>&1; then
    if git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git -C "$SCRIPT_DIR" rev-parse --short HEAD
      return
    fi
  fi
  echo "unknown"
}

expand_bundles() {
  local raw="$1"
  local token
  raw="${raw//,/ }"
  for token in $raw; do
    token="${token//[[:space:]]/}"
    [[ -z "$token" ]] && continue
    if [[ "$token" == @* ]]; then
      local file_path="${token#@}"
      if [[ ! -f "$file_path" ]]; then
        err "Bundle file not found: $file_path"
        exit 1
      fi
      local line
      while IFS= read -r line; do
        line="${line%%#*}"
        line="${line//,/ }"
        expand_bundles "$line"
      done < "$file_path"
    else
      printf '%s\n' "$token"
    fi
  done
}

apt_update() {
  local i
  for i in 1 2 3; do
    if $SUDO apt-get update -y; then
      return 0
    fi
    warn "apt-get update failed (attempt $i); retrying..."
    sleep 2
  done
  err "apt-get update failed after multiple attempts."
  exit 1
}

refresh_apt() {
  export DEBIAN_FRONTEND=noninteractive
  apt_update
  $SUDO apt-get install -y --no-install-recommends apt-transport-https ca-certificates gnupg lsb-release curl wget
}

fetch_pkg_list() {
  local list_name="$1"
  if ! curl -fsSL --retry 3 --retry-delay 2 --retry-connrefused \
    "$PKG_DIR_URL/${list_name}.txt" | sed -e 's/#.*$//' -e '/^\s*$/d'; then
    err "Failed to fetch package list: ${list_name}"
    exit 1
  fi
}

install_apt_packages() {
  local pkgs=("$@")
  if ((${#pkgs[@]})); then
    log "Installing APT packages: ${pkgs[*]}"
    if [[ "$DRY_RUN" == "1" || "$DRY_RUN" == "true" ]]; then
      warn "Dry run enabled; skipping package installation."
      return 0
    fi
    $SUDO apt-get install -y --no-install-recommends "${pkgs[@]}"
  else
    warn "No packages to install in this step."
  fi
}

validate_packages() {
  local pkgs=("$@")
  local missing=()
  local pkg
  for pkg in "${pkgs[@]}"; do
    if ! apt-cache show "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done
  if ((${#missing[@]})); then
    err "Package(s) not found in APT cache: ${missing[*]}"
    exit 1
  fi
}

install_tailscale() {
  # Official one-liner from Tailscale team:
  curl -fsSL --retry 3 --retry-delay 2 --retry-connrefused https://tailscale.com/install.sh | $SUDO sh
}

install_docker() {
  # Docker’s supported install for Debian/Ubuntu
  # Ref: https://docs.docker.com/engine/install/
  $SUDO apt-get install -y --no-install-recommends ca-certificates curl
  $SUDO install -m 0755 -d /etc/apt/keyrings
  curl -fsSL --retry 3 --retry-delay 2 --retry-connrefused \
    https://download.docker.com/linux/${DIST_ID}/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DIST_ID} \
    ${DIST_VER} stable" | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
  apt_update
  $SUDO apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  if [[ -n "${SUDO_USER:-}" ]] && id -u "$SUDO_USER" >/dev/null 2>&1; then
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
      --list-bundles)
        LIST_BUNDLES=1; shift;;
      --print-packages)
        PRINT_PACKAGES=1; shift;;
      --validate-packages)
        VALIDATE_PACKAGES=1; shift;;
      --validate-only)
        VALIDATE_PACKAGES=1; VALIDATE_ONLY=1; shift;;
      --dry-run)
        DRY_RUN=1; shift;;
      --step|--interactive)
        STEP_MODE=1; shift;;
      -V|--version)
        show_version
        exit 0;;
      -h|--help)
        usage
        exit 0;;
      *)
        warn "Ignoring unknown arg: $1"; shift;;
    esac
  done
}

main() {
  parse_flags "$@"
  if [[ "$LIST_BUNDLES" == "1" ]]; then
    list_bundles
    exit 0
  fi
  STEP_NO=0
  step "Acquire privileges"
  need_sudo
  step "Detect system"
  detect_distro
  detect_arch
  if [[ -z "${DIST_VER}" && ( "$WITH_DOCKER" == "1" || "$WITH_DOCKER" == "true" ) ]]; then
    err "VERSION_CODENAME is missing; Docker repo setup requires it."
    exit 1
  fi
  step "Refresh APT metadata"
  refresh_apt

  # Merge packages from selected bundles
  step "Resolve bundle package lists"
  if [[ "${BUNDLES}" == +* ]]; then
    BUNDLES="base,${BUNDLES#+}"
  fi
  mapfile -t bundle_arr < <(expand_bundles "$BUNDLES")
  declare -a to_install=()
  for b in "${bundle_arr[@]}"; do
    b="${b//[[:space:]]/}"
    [[ -z "$b" ]] && continue
    log "Loading package list: $b"
    mapfile -t pkgs < <(fetch_pkg_list "$b")
    to_install+=("${pkgs[@]}")
  done

  # Deduplicate
  if ((${#to_install[@]})); then
    mapfile -t to_install < <(printf "%s\n" "${to_install[@]}" | awk 'NF' | sort -u)
  fi

  if [[ "$PRINT_PACKAGES" == "1" ]]; then
    printf "%s\n" "${to_install[@]}"
    exit 0
  fi
  if [[ "$VALIDATE_PACKAGES" == "1" || "$VALIDATE_PACKAGES" == "true" ]]; then
    step "Validate packages"
    validate_packages "${to_install[@]}"
    if [[ "$VALIDATE_ONLY" == "1" ]]; then
      log "Validation OK."
      exit 0
    fi
  fi

  step "Install APT packages"
  install_apt_packages "${to_install[@]}"

  # Optional installers
  if [[ "$WITH_TAILSCALE" == "1" || "$WITH_TAILSCALE" == "true" ]]; then
    step "Install Tailscale"
    log "Installing Tailscale..."
    if [[ "$DRY_RUN" == "1" || "$DRY_RUN" == "true" ]]; then
      warn "Dry run enabled; skipping Tailscale install."
    else
      install_tailscale
    fi
  fi
  if [[ "$WITH_DOCKER" == "1" || "$WITH_DOCKER" == "true" ]]; then
    step "Install Docker"
    log "Installing Docker Engine & Compose plugin..."
    if [[ "$DRY_RUN" == "1" || "$DRY_RUN" == "true" ]]; then
      warn "Dry run enabled; skipping Docker install."
    else
      install_docker
    fi
  fi

  step "Cleanup"
  if [[ "$DRY_RUN" == "1" || "$DRY_RUN" == "true" ]]; then
    warn "Dry run enabled; skipping apt autoremove."
  else
    $SUDO apt-get autoremove -y
  fi
  log "All done! You can edit package lists in GitHub and re-run any time."
}

main "$@"
