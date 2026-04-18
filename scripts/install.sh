#!/usr/bin/env bash
# install.sh — Bootstrap vm-init from a GitHub release tarball.
#
# This script is standalone by design (it runs BEFORE vm-init is installed),
# so it ships its own minimal color/symbol UI instead of sourcing _common.sh.

set -euo pipefail

# Edit this default once when you publish this repo.
VM_INIT_REPO_DEFAULT="wagga40/vm-init"

: "${VM_INIT_REPO:=${VM_INIT_REPO_DEFAULT}}"
: "${VM_INIT_VERSION:=latest}"
: "${VM_INIT_PREFIX:=/opt/vm-init}"
: "${VM_INIT_BIN_DIR:=/usr/local/sbin}"
: "${VM_INIT_NO_SYMLINK:=0}"
: "${VM_INIT_NO_RUN:=1}"

# ---------- Minimal UI (mirrors modules/_common.sh for visual consistency) ----------
_install_detect_ui() {
  local use_color=0 use_unicode=0
  if [[ "${VM_INIT_FORCE_COLOR:-0}" == "1" ]]; then
    use_color=1
  elif [[ -z "${NO_COLOR:-}" && "${VM_INIT_NO_COLOR:-0}" != "1" ]] \
       && [[ -t 1 ]] && tput colors &>/dev/null; then
    use_color=1
  fi
  case "${LC_ALL:-}${LC_CTYPE:-}${LANG:-}" in
    *UTF-8*|*UTF8*|*utf-8*|*utf8*) use_unicode=1 ;;
  esac

  if (( use_color )); then
    _C_RESET="\033[0m" _C_BOLD="\033[1m" _C_DIM="\033[2m"
    _C_GREEN="\033[32m" _C_CYAN="\033[36m" _C_YELLOW="\033[33m"
    _C_RED="\033[31m" _C_MAGENTA="\033[35m" _C_BLUE="\033[34m"
    _C_BRIGHT_GREEN="\033[92m" _C_BRIGHT_CYAN="\033[96m"
  else
    _C_RESET="" _C_BOLD="" _C_DIM=""
    _C_GREEN="" _C_CYAN="" _C_YELLOW="" _C_RED=""
    _C_MAGENTA="" _C_BLUE=""
    _C_BRIGHT_GREEN="" _C_BRIGHT_CYAN=""
  fi

  if (( use_color && use_unicode )); then
    _SYM_ARROW="▶" _SYM_OK="✔" _SYM_WARN="▲" _SYM_FAIL="✘" _SYM_INFO="ℹ"
  else
    _SYM_ARROW="==>" _SYM_OK="[OK]" _SYM_WARN="[!!]" _SYM_FAIL="[XX]" _SYM_INFO="[ii]"
  fi
}
_install_detect_ui

log_step() { echo -e "${_C_CYAN}${_C_BOLD}${_SYM_ARROW}${_C_RESET} ${_C_BOLD}$1${_C_RESET}"; }
log_ok()   { echo -e "  ${_C_GREEN}${_SYM_OK}${_C_RESET} $1"; }
log_info() { echo -e "  ${_C_BLUE}${_SYM_INFO}${_C_RESET} $1"; }
log_warn() { echo -e "  ${_C_YELLOW}${_SYM_WARN}${_C_RESET} $1" >&2; }
log_fail() { echo -e "  ${_C_RED}${_SYM_FAIL}${_C_RESET} $1" >&2; }
err()      { log_fail "$*"; exit 1; }

_opt() { printf "    ${_C_BOLD}%-22s${_C_RESET} %s\n" "$1" "$2"; }
_env() { printf "    ${_C_BOLD}%-22s${_C_RESET} %s\n" "$1" "$2"; }
_section() { echo ""; echo -e "${_C_BOLD}${_C_MAGENTA}$1${_C_RESET}"; }

usage() {
  echo -e "${_C_BOLD}vm-init installer${_C_RESET} ${_C_DIM}—${_C_RESET} Bootstrap vm-init from a GitHub release tarball"

  _section "Usage:"
  echo "  curl -fsSL https://raw.githubusercontent.com/wagga40/vm-init/main/scripts/install.sh \\"
  echo "    | sudo bash"
  echo ""
  echo "  sudo bash scripts/install.sh [options]"

  _section "Options:"
  _opt "--repo <owner/repo>"   "GitHub repo to pull from (overrides VM_INIT_REPO)"
  _opt "--version <tag>"       "Release tag to install (e.g. v1.0). Default: latest"
  _opt "--prefix <dir>"        "Install directory (default: /opt/vm-init)"
  _opt "--no-symlink"          "Skip creating symlinks under /usr/local/sbin"
  _opt "--no-run"              "Don't auto-run vm-init after install (default)"
  _opt "--help, -h"            "Show this help"

  _section "Environment:"
  _env "VM_INIT_REPO"         "<owner>/<repo> to pull from"
  _env "VM_INIT_VERSION"      "Release tag (default: latest)"
  _env "VM_INIT_PREFIX"       "Install directory (default: /opt/vm-init)"
  _env "VM_INIT_BIN_DIR"      "Symlink directory (default: /usr/local/sbin)"
  _env "VM_INIT_NO_SYMLINK"   "Set to 1 to skip symlinks"
  _env "VM_INIT_NO_RUN"       "Set to 1 to skip auto-run (default: 1)"
  _env "GH_TOKEN / GITHUB_TOKEN" "Authenticate GitHub API (higher rate limits)"

  _section "Examples:"
  echo -e "  ${_C_DIM}# Install latest release from a specific repo${_C_RESET}"
  echo -e "  ${_C_CYAN}VM_INIT_REPO=yourname/vm-init sudo -E bash scripts/install.sh${_C_RESET}"
  echo ""
  echo -e "  ${_C_DIM}# Pin a specific version${_C_RESET}"
  echo -e "  ${_C_CYAN}sudo bash scripts/install.sh --repo yourname/vm-init --version v1.0${_C_RESET}"
  echo ""
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)        VM_INIT_REPO="$2"; shift 2 ;;
    --version)     VM_INIT_VERSION="$2"; shift 2 ;;
    --prefix)      VM_INIT_PREFIX="$2"; shift 2 ;;
    --no-symlink)  VM_INIT_NO_SYMLINK=1; shift ;;
    --no-run)      VM_INIT_NO_RUN=1; shift ;;
    --help|-h)     usage; exit 0 ;;
    *)             echo -e "${_C_RED}${_SYM_FAIL}${_C_RESET} Unknown option: ${_C_BOLD}$1${_C_RESET}" >&2
                   echo "" >&2
                   usage >&2
                   exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  err "This installer must run as root (use: curl ... | sudo bash)"
fi

if [[ "$VM_INIT_REPO" == "$VM_INIT_REPO_DEFAULT" || "$VM_INIT_REPO" == *"REPLACE_ME"* ]]; then
  err "VM_INIT_REPO is not configured. Set it via env or edit VM_INIT_REPO_DEFAULT at the top of scripts/install.sh.
     Example: VM_INIT_REPO=yourname/vm-init sudo -E bash scripts/install.sh"
fi

for bin in curl tar sha256sum; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    # sha256sum may be shasum on non-GNU systems
    if [[ "$bin" == "sha256sum" ]] && command -v shasum >/dev/null 2>&1; then
      continue
    fi
    err "Missing required tool: ${bin}"
  fi
done

echo ""
echo -e "${_C_BOLD}${_C_CYAN}vm-init installer${_C_RESET}"
printf "  ${_C_DIM}%-10s${_C_RESET} ${_C_BOLD}%s${_C_RESET}\n" "Repo:"    "${VM_INIT_REPO}"
printf "  ${_C_DIM}%-10s${_C_RESET} ${_C_BOLD}%s${_C_RESET}\n" "Version:" "${VM_INIT_VERSION}"
printf "  ${_C_DIM}%-10s${_C_RESET} ${_C_BOLD}%s${_C_RESET}\n" "Prefix:"  "${VM_INIT_PREFIX}"
echo ""

resolve_latest_tag() {
  local api="https://api.github.com/repos/${VM_INIT_REPO}/releases/latest"
  local auth_hdr=()
  [[ -n "${GH_TOKEN:-}" ]]     && auth_hdr=(-H "Authorization: Bearer ${GH_TOKEN}")
  [[ -n "${GITHUB_TOKEN:-}" ]] && auth_hdr=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  curl -fsSL "${auth_hdr[@]}" "$api" \
    | grep -m1 '"tag_name"' \
    | sed -E 's/.*"tag_name"\s*:\s*"([^"]+)".*/\1/'
}

TAG="$VM_INIT_VERSION"
if [[ "$TAG" == "latest" ]]; then
  log_step "Resolving latest release tag"
  TAG=$(resolve_latest_tag) || err "Could not resolve latest release from GitHub"
  [[ -z "$TAG" ]] && err "Empty tag returned from GitHub API"
  log_info "Tag: ${_C_BOLD}${TAG}${_C_RESET}"
fi

VERSION="${TAG#v}"
BASE_URL="https://github.com/${VM_INIT_REPO}/releases/download/${TAG}"
TARBALL_NAME="vm-init-${VERSION}.tar.gz"
TARBALL_URL="${BASE_URL}/${TARBALL_NAME}"
SHA_URL="${TARBALL_URL}.sha256"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

log_step "Downloading ${TARBALL_NAME}"
if ! curl -fsSL "$TARBALL_URL" -o "$TMP/$TARBALL_NAME"; then
  err "Failed to download $TARBALL_URL
     (tip: set VM_INIT_VERSION to a specific tag if 'latest' has a different asset name)"
fi

log_step "Downloading sha256 checksum"
if ! curl -fsSL "$SHA_URL" -o "$TMP/$TARBALL_NAME.sha256"; then
  err "Failed to download ${SHA_URL}"
fi

log_step "Verifying checksum"
(
  cd "$TMP"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c "$TARBALL_NAME.sha256" >/dev/null
  else
    shasum -a 256 -c "$TARBALL_NAME.sha256" >/dev/null
  fi
) || err "Checksum verification failed"
log_ok "Checksum matches"

log_step "Installing to ${VM_INIT_PREFIX}"
mkdir -p "$(dirname "$VM_INIT_PREFIX")"
rm -rf "${VM_INIT_PREFIX}.old"
if [[ -d "$VM_INIT_PREFIX" ]]; then
  mv "$VM_INIT_PREFIX" "${VM_INIT_PREFIX}.old"
fi

tar xzf "$TMP/$TARBALL_NAME" -C "$TMP"
extract_dir="$TMP/vm-init-${VERSION}"
[[ -d "$extract_dir" ]] || err "Unexpected tarball layout (no ${extract_dir})"
mv "$extract_dir" "$VM_INIT_PREFIX"
chmod +x "$VM_INIT_PREFIX/vm-init.sh"
[[ -f "$VM_INIT_PREFIX/scripts/install.sh" ]] && chmod +x "$VM_INIT_PREFIX/scripts/install.sh"
[[ -d "$VM_INIT_PREFIX/scripts"    ]] && chmod +x "$VM_INIT_PREFIX"/scripts/*.sh
[[ -f "$VM_INIT_PREFIX/modules/recover-dns.sh" ]] && chmod +x "$VM_INIT_PREFIX/modules/recover-dns.sh"

if [[ "$VM_INIT_NO_SYMLINK" != "1" ]]; then
  log_step "Creating symlinks under ${VM_INIT_BIN_DIR}"
  mkdir -p "$VM_INIT_BIN_DIR"
  ln -sf "$VM_INIT_PREFIX/vm-init.sh" "$VM_INIT_BIN_DIR/vm-init"
  if [[ -f "$VM_INIT_PREFIX/modules/recover-dns.sh" ]]; then
    ln -sf "$VM_INIT_PREFIX/modules/recover-dns.sh" "$VM_INIT_BIN_DIR/vm-init-recover-dns"
  fi
fi

rm -rf "${VM_INIT_PREFIX}.old"

echo ""
echo -e "${_C_BRIGHT_GREEN}${_C_BOLD}${_SYM_OK}${_C_RESET} ${_C_BOLD}vm-init ${TAG} installed${_C_RESET} at ${_C_CYAN}${VM_INIT_PREFIX}${_C_RESET}"
echo ""
echo -e "${_C_BOLD}Next steps${_C_RESET}"
if [[ "$VM_INIT_NO_SYMLINK" != "1" ]]; then
  printf "  ${_C_DIM}%-18s${_C_RESET} ${_C_CYAN}%s${_C_RESET}\n" "Run:"          "sudo vm-init"
  printf "  ${_C_DIM}%-18s${_C_RESET} ${_C_CYAN}%s${_C_RESET}\n" "DNS recovery:" "sudo vm-init-recover-dns --with-fallback"
else
  printf "  ${_C_DIM}%-18s${_C_RESET} ${_C_CYAN}%s${_C_RESET}\n" "Run:" "sudo ${VM_INIT_PREFIX}/vm-init.sh"
fi
printf "  ${_C_DIM}%-18s${_C_RESET} %s\n" "Custom config:" "Create /etc/vm-init/vm-init.yml (takes precedence over the default)"
printf "  ${_C_DIM}%-18s${_C_RESET} ${_C_CYAN}%s${_C_RESET}\n" "Preview first:" "sudo vm-init --dry-run"

if [[ "$VM_INIT_NO_RUN" != "1" ]]; then
  echo ""
  log_step "Running vm-init"
  exec "$VM_INIT_PREFIX/vm-init.sh"
fi
