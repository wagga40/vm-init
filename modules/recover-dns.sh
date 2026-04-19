#!/usr/bin/env bash
# recover-dns.sh
# Break-glass recovery for blocked DNS after dnsproxy/systemd-resolved changes.

set -euo pipefail

# Resolve script directory, following symlinks so sourcing works whether
# we're invoked via /opt/vm-init/modules/recover-dns.sh or the symlink
# /usr/local/sbin/vm-init-recover-dns.
_self="$0"
if command -v readlink >/dev/null 2>&1; then
  _self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
fi
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd)"

# Source shared UI helpers from this directory if available.
# Fall back to a minimal inline palette so this script still works if run
# from a vendored location without _common.sh nearby.
COMMON_SH="${SCRIPT_DIR}/_common.sh"
if [[ -f "$COMMON_SH" ]]; then
  # shellcheck source=modules/_common.sh disable=SC1091
  source "$COMMON_SH"
else
  if [[ -t 1 ]] && tput colors &>/dev/null; then
    _C_RESET="\033[0m" _C_BOLD="\033[1m" _C_DIM="\033[2m"
    _C_GREEN="\033[32m" _C_CYAN="\033[36m" _C_YELLOW="\033[33m"
    _C_RED="\033[31m" _C_MAGENTA="\033[35m" _C_BLUE="\033[34m"
    _C_BRIGHT_GREEN="\033[92m"
  else
    _C_RESET="" _C_BOLD="" _C_DIM="" _C_GREEN="" _C_CYAN=""
    _C_YELLOW="" _C_RED="" _C_MAGENTA="" _C_BLUE="" _C_BRIGHT_GREEN=""
  fi
  _SYM_ARROW="==>" _SYM_OK="[OK]" _SYM_WARN="[!!]" _SYM_FAIL="[XX]" _SYM_INFO="[ii]"
  log_step() { echo -e "${_C_CYAN}${_C_BOLD}${_SYM_ARROW}${_C_RESET} ${_C_BOLD}$1${_C_RESET}"; }
  log_ok()   { echo -e "  ${_C_GREEN}${_SYM_OK}${_C_RESET} $1"; }
  log_info() { echo -e "  ${_C_BLUE}${_SYM_INFO}${_C_RESET} $1"; }
  log_warn() { echo -e "  ${_C_YELLOW}${_SYM_WARN}${_C_RESET} $1" >&2; }
  log_fail() { echo -e "  ${_C_RED}${_SYM_FAIL}${_C_RESET} $1" >&2; }
  log_done() { echo -e "${_C_BRIGHT_GREEN}${_C_BOLD}${_SYM_OK}${_C_RESET} ${_C_BOLD}$1${_C_RESET}"; }
  print_help_section() { echo ""; echo -e "${_C_BOLD}${_C_MAGENTA}$1${_C_RESET}"; }
fi

IFACE=""
WITH_FALLBACK=0
FALLBACK_DNS="1.1.1.1 9.9.9.9"
FALLBACK_DNS_ALT="8.8.8.8"

_opt() { printf "    ${_C_BOLD}%-22s${_C_RESET} %s\n" "$1" "$2"; }

usage() {
  echo -e "${_C_BOLD}vm-init-recover-dns${_C_RESET} ${_C_DIM}—${_C_RESET} Break-glass DNS recovery after dnsproxy changes"

  print_help_section "Usage:"
  echo "  sudo $0 [options]"

  print_help_section "Options:"
  _opt "--iface <name>"        "Interface to revert (default: auto-detect from default route)"
  _opt "--with-fallback"       "Write a temporary public-resolver fallback file"
  _opt "--fallback \"<list>\""   "Space-separated DNS servers (default: \"1.1.1.1 9.9.9.9\")"
  _opt "--help"                "Show this help"

  print_help_section "Examples:"
  echo -e "  ${_C_DIM}# Revert + install a temporary public fallback (1.1.1.1, 9.9.9.9)${_C_RESET}"
  echo -e "  ${_C_CYAN}sudo $0 --with-fallback${_C_RESET}"
  echo ""
  echo -e "  ${_C_DIM}# Revert just a specific interface with custom fallback resolvers${_C_RESET}"
  echo -e "  ${_C_CYAN}sudo $0 --iface wlan0 --with-fallback --fallback \"8.8.8.8 1.0.0.1\"${_C_RESET}"
  echo ""
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iface)         IFACE="$2"; shift 2 ;;
    --with-fallback) WITH_FALLBACK=1; shift ;;
    --fallback)      FALLBACK_DNS="$2"; shift 2 ;;
    --help|-h)       usage; exit 0 ;;
    *)               echo -e "${_C_RED}${_SYM_FAIL}${_C_RESET} Unknown option: ${_C_BOLD}$1${_C_RESET}" >&2
                     echo "" >&2
                     usage >&2
                     exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  log_fail "Run as root: sudo $0"
  exit 1
fi

if [[ -z "$IFACE" ]]; then
  IFACE=$(ip route | awk '/^default / { print $5; exit }' || true)
fi

echo ""
echo -e "${_C_BOLD}${_C_MAGENTA}━━━ DNS recovery ━━━${_C_RESET}"
[[ -n "$IFACE" ]] && log_info "Interface: ${_C_BOLD}${IFACE}${_C_RESET}"

log_step "Disabling dnsproxy and removing custom unit/drop-in"
systemctl disable --now dnsproxy vm-init-dns-pin >/dev/null 2>&1 || true
rm -f /etc/systemd/system/dnsproxy.service
rm -f /etc/systemd/system/vm-init-dns-pin.service
rm -f /etc/systemd/system/systemd-resolved.service.d/10-vm-init-dnsproxy.conf
rmdir /etc/systemd/system/systemd-resolved.service.d 2>/dev/null || true
rm -f /etc/systemd/resolved.conf.d/99-vm-init-dnsproxy.conf
rm -f /usr/local/sbin/vm-init-dns-pin

log_step "Reloading units and reverting per-link override"
systemctl daemon-reload
if command -v resolvectl >/dev/null 2>&1 && [[ -n "$IFACE" ]]; then
  resolvectl revert "$IFACE" >/dev/null 2>&1 || true
fi

log_step "Restarting systemd-resolved"
systemctl restart systemd-resolved

log_step "Restoring /etc/resolv.conf symlink"
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

if [[ "$WITH_FALLBACK" == "1" ]]; then
  log_step "Writing temporary fallback DNS config"
  log_info "DNS=${_C_BOLD}${FALLBACK_DNS}${_C_RESET} FallbackDNS=${_C_BOLD}${FALLBACK_DNS_ALT}${_C_RESET}"
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/00-recovery-dns.conf <<EOF
[Resolve]
DNS=${FALLBACK_DNS}
FallbackDNS=${FALLBACK_DNS_ALT}
EOF
  systemctl restart systemd-resolved
fi

log_step "Verifying DNS"
if getent hosts example.com >/dev/null 2>&1; then
  log_ok "DNS resolution works (example.com)."
else
  log_warn "DNS still failing. Check: systemctl status systemd-resolved --no-pager"
  exit 1
fi

echo ""
log_done "DNS recovery complete."
echo ""
echo -e "${_C_BOLD}Next steps${_C_RESET}"
echo -e "  ${_C_DIM}1.${_C_RESET} Set ${_C_CYAN}dns.enabled: false${_C_RESET} in ${_C_CYAN}vm-init.yml${_C_RESET} before re-running vm-init."
echo -e "  ${_C_DIM}2.${_C_RESET} Re-enable the DNS module only after testing DNS settings manually."
