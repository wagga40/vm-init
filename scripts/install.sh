#!/usr/bin/env bash
# install.sh — Bootstrap vm-init from a GitHub release tarball.
#
# This script is standalone by design (it runs BEFORE vm-init is installed),
# so it ships its own minimal color/symbol UI instead of sourcing _common.sh.

set -euo pipefail

# Edit this single line if you fork to another GitHub repo.
VM_INIT_REPO="wagga40/vm-init"

: "${VM_INIT_VERSION:=latest}"
: "${VM_INIT_PREFIX:=/opt/vm-init}"
: "${VM_INIT_BIN_DIR:=/usr/local/bin}"
: "${VM_INIT_NO_SYMLINK:=0}"

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

install_curl() {
  curl -fsSL \
    --retry 3 --retry-delay 2 --retry-connrefused \
    --connect-timeout "${VM_INIT_CURL_CONNECT_TIMEOUT:-15}" \
    --max-time "${VM_INIT_CURL_MAX_TIME:-300}" \
    "$@"
}

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
  _opt "--version <tag>"       "Release tag to install. Default: latest"
  _opt "--prefix <dir>"        "Install directory (managed default: /opt/vm-init)"
  _opt "--no-symlink"          "Skip creating symlinks under /usr/local/bin"
  _opt "--help, -h"            "Show this help"

  _section "Environment:"
  _env "VM_INIT_VERSION"      "Release tag (default: latest)"
  _env "VM_INIT_PREFIX"       "Install directory (default: /opt/vm-init)"
  _env "VM_INIT_BIN_DIR"      "Symlink directory (default: /usr/local/bin)"
  _env "VM_INIT_NO_SYMLINK"   "Set to 1 to skip symlinks"

  _section "Examples:"
  echo -e "  ${_C_DIM}# Install the latest release${_C_RESET}"
  echo -e "  ${_C_CYAN}curl -fsSL https://raw.githubusercontent.com/${VM_INIT_REPO}/main/scripts/install.sh | sudo bash${_C_RESET}"
  echo ""
}

require_option_value() {
  local flag="$1"
  local value="${2-}"
  if [[ -z "$value" || "$value" == -* ]]; then
    log_fail "Missing value for ${flag}"
    echo "" >&2
    usage >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)     require_option_value "$1" "${2-}"; VM_INIT_VERSION="$2"; shift 2 ;;
    --prefix)      require_option_value "$1" "${2-}"; VM_INIT_PREFIX="$2"; shift 2 ;;
    --no-symlink)  VM_INIT_NO_SYMLINK=1; shift ;;
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

if [[ ! -f /etc/os-release ]] || ! grep -qi ubuntu /etc/os-release; then
  err "This installer supports Ubuntu"
fi
while [[ "$VM_INIT_PREFIX" != / && "$VM_INIT_PREFIX" == */ ]]; do VM_INIT_PREFIX="${VM_INIT_PREFIX%/}"; done
case "$VM_INIT_PREFIX" in
  /|/etc|/usr|/usr/local|/opt|/root|/home|*..*) err 'Choose a dedicated absolute installation directory' ;;
  /*) ;;
  *) err '--prefix must be an absolute path' ;;
esac

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
printf "  ${_C_DIM}%-10s${_C_RESET} ${_C_BOLD}%s${_C_RESET}\n" "Version:" "${VM_INIT_VERSION}"
printf "  ${_C_DIM}%-10s${_C_RESET} ${_C_BOLD}%s${_C_RESET}\n" "Prefix:"  "${VM_INIT_PREFIX}"
echo ""

TARBALL_NAME="vm-init.tar.gz"
if [[ "$VM_INIT_VERSION" == "latest" ]]; then
  TARBALL_URL="https://github.com/${VM_INIT_REPO}/releases/latest/download/${TARBALL_NAME}"
else
  TARBALL_URL="https://github.com/${VM_INIT_REPO}/releases/download/${VM_INIT_VERSION}/${TARBALL_NAME}"
fi
SHA_URL="${TARBALL_URL}.sha256"

TMP=$(mktemp -d)
STAGE=""
installer_cleanup() {
  [[ -z "$STAGE" ]] || rm -rf "$STAGE"
  rm -rf "$TMP"
}
trap installer_cleanup EXIT

log_step "Downloading ${TARBALL_NAME}"
if ! install_curl "$TARBALL_URL" -o "$TMP/$TARBALL_NAME"; then
  err "Failed to download $TARBALL_URL"
fi

log_step "Downloading sha256 checksum"
if ! install_curl "$SHA_URL" -o "$TMP/$TARBALL_NAME.sha256"; then
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
# Load shared installation helpers only from the checksum-verified archive.
mkdir -p "$TMP/release"
tar xzf "$TMP/$TARBALL_NAME" -C "$TMP/release" --strip-components=1
[[ -f "$TMP/release/vm-init.sh" && -f "$TMP/release/modules/_layout.sh" ]] \
  || err 'Release archive is incomplete or predates the supported installation layout'
bash -n "$TMP/release/vm-init.sh" || err 'Release script is not valid Bash'
# shellcheck disable=SC1091 # loaded from the verified release
source "$TMP/release/modules/_common.sh"
# shellcheck disable=SC1091
source "$TMP/release/modules/_safety.sh"
validate_install_prefix && acquire_run_lock && migrate_layout && preserve_legacy_config || exit 1
install -d -m 0755 "$VM_INIT_PREFIX"
STAGE=$(mktemp -d "$VM_INIT_PREFIX/.app-stage.XXXXXX")
cp -a "$TMP/release/." "$STAGE/"
install_app "$STAGE" vm-init.sh || err 'Installation failed; the previous application was retained'
STAGE=""
link_legacy_app || exit 1
log_ok "vm-init installed at $VM_INIT_PREFIX"
if [[ "$VM_INIT_NO_SYMLINK" == 1 ]]; then
  printf 'Run: sudo %q\n' "$VM_INIT_PREFIX/bin/vm-init"
else
  printf 'Run: sudo vm-init\n'
fi
printf 'The first run prepares configuration tools, guides configuration, and applies it.\n'
