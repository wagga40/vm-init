#!/usr/bin/env bash
# vm-init.sh — Config-driven Ubuntu machine setup.

set -euo pipefail

# Resolve script directory, following symlinks so sourcing works whether we're
# invoked as /opt/vm-init/vm-init.sh or via the /usr/local/sbin/vm-init symlink
# that install.sh creates.
_self="$0"
if command -v readlink >/dev/null 2>&1; then
  _self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
fi
SCRIPT_DIR="$(cd "$(dirname "$_self")" && pwd)"
unset _self
MODULES_DIR="${SCRIPT_DIR}/modules"
SCRIPT_NAME="$(basename "$0")"

# Source shared UI + helper library before parsing args so --help etc.
# can render with color and symbols. In single-file bundles the helpers are
# already defined in the enclosing script, so we skip re-sourcing.
if ! declare -F log_step >/dev/null 2>&1; then
  # shellcheck source=modules/_common.sh
  source "${MODULES_DIR}/_common.sh"
fi

# Default-config emitter. In the repo layout this reads vm-init.yml from
# alongside the orchestrator. Single-file bundles pre-define this function
# with an inlined YAML heredoc; the guard below preserves that definition.
if ! declare -F _emit_default_config >/dev/null 2>&1; then
  _emit_default_config() {
    if [[ -f "${SCRIPT_DIR}/vm-init.yml" ]]; then
      cat "${SCRIPT_DIR}/vm-init.yml"
      return 0
    fi
    return 1
  }
fi

# Config precedence (without --config):
#   1) /etc/vm-init/vm-init.yml (system-wide override)
#   2) ./vm-init.yml (project/local override in current directory)
#   3) <script dir>/vm-init.yml (default shipped with tarball install)
#   4) embedded default (single-file bundle fallback)
# Override everything explicitly with --config.
CONFIG_EXPLICIT=0
if [[ -f "/etc/vm-init/vm-init.yml" ]]; then
  CONFIG="/etc/vm-init/vm-init.yml"
elif [[ -f "$(pwd)/vm-init.yml" ]]; then
  CONFIG="$(pwd)/vm-init.yml"
else
  CONFIG="${SCRIPT_DIR}/vm-init.yml"
fi

VERSION_FILE="${SCRIPT_DIR}/VERSION"
if [[ -n "${VM_INIT_BUNDLED_VERSION:-}" ]]; then
  VM_INIT_VERSION="${VM_INIT_BUNDLED_VERSION}"
elif [[ -f "$VERSION_FILE" ]]; then
  VM_INIT_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")
else
  VM_INIT_VERSION="0.0.0-dev"
fi
export VM_INIT_VERSION

: "${VM_INIT_UPDATE_REPO:=wagga40/vm-init}"
: "${VM_INIT_UPDATE_CHECK:=1}"
VM_INIT_UPDATE_API_URL="https://api.github.com/repos/${VM_INIT_UPDATE_REPO}/releases/latest"
VM_INIT_UPDATE_DOWNLOAD_URL="https://github.com/${VM_INIT_UPDATE_REPO}/releases/latest/download/vm-init"

detect_run_mode() {
  if [[ "${VM_INIT_BUNDLED:-0}" == "1" ]]; then
    echo "bundled_single_file"
    return 0
  fi
  if [[ "$SCRIPT_DIR" == "/opt/vm-init" || "$SCRIPT_DIR" == "/opt/vm-init/"* ]]; then
    echo "installed_tarball"
    return 0
  fi
  echo "local_checkout"
}

normalize_semver() {
  local raw="${1#v}"
  raw="${raw%%-*}"
  if [[ "$raw" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$raw"
    return 0
  fi
  return 1
}

is_version_newer() {
  local latest local_ver
  local latest_norm local_norm
  local lmaj lmin lpatch cmaj cmin cpatch

  latest="$1"
  local_ver="$2"

  latest_norm=$(normalize_semver "$latest") || return 1
  local_norm=$(normalize_semver "$local_ver") || return 1

  IFS='.' read -r lmaj lmin lpatch <<< "$latest_norm"
  IFS='.' read -r cmaj cmin cpatch <<< "$local_norm"

  if (( lmaj > cmaj )); then return 0; fi
  if (( lmaj < cmaj )); then return 1; fi
  if (( lmin > cmin )); then return 0; fi
  if (( lmin < cmin )); then return 1; fi
  if (( lpatch > cpatch )); then return 0; fi
  return 1
}

latest_release_version() {
  local response tag

  if [[ -n "${VM_INIT_UPDATE_LATEST_OVERRIDE:-}" ]]; then
    echo "$VM_INIT_UPDATE_LATEST_OVERRIDE"
    return 0
  fi

  [[ "${VM_INIT_UPDATE_CHECK}" == "1" ]] || return 1
  command -v curl >/dev/null 2>&1 || return 1

  response="$(curl -fsSL --max-time 4 "$VM_INIT_UPDATE_API_URL" 2>/dev/null || true)"
  [[ -n "$response" ]] || return 1

  tag="$(printf '%s' "$response" | tr -d '\n' | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"
  [[ -n "$tag" ]] || return 1
  echo "$tag"
}

print_update_notice_if_needed() {
  local latest

  [[ "${VM_INIT_UPDATE_CHECK}" == "1" ]] || return 0
  latest="$(latest_release_version || true)"
  [[ -n "$latest" ]] || return 0
  is_version_newer "$latest" "$VM_INIT_VERSION" || return 0

  echo ""
  log_info "New vm-init version available."
  echo -e "  ${_C_DIM}Current:${_C_RESET} ${_C_BOLD}${VM_INIT_VERSION}${_C_RESET}"
  echo -e "  ${_C_DIM}Latest:${_C_RESET}  ${_C_BOLD}${latest#v}${_C_RESET}"
  echo -e "  ${_C_DIM}Download:${_C_RESET} ${_C_CYAN}${VM_INIT_UPDATE_DOWNLOAD_URL}${_C_RESET}"

  case "${VM_INIT_RUN_MODE}" in
    installed_tarball)
      echo -e "  ${_C_DIM}Tip:${_C_RESET} run ${_C_CYAN}sudo ${SCRIPT_NAME} --update${_C_RESET} to refresh /opt/vm-init."
      ;;
    bundled_single_file|local_checkout)
      echo -e "  ${_C_DIM}Tip:${_C_RESET} download the latest release asset or update your checkout before the next run."
      ;;
  esac
}

run_update_cmd() {
  local latest installer
  latest="$(latest_release_version || true)"

  case "${VM_INIT_RUN_MODE}" in
    installed_tarball)
      installer="${SCRIPT_DIR}/scripts/install.sh"
      if [[ ! -f "$installer" ]]; then
        log_fail "Installer not found: ${installer}"
        return 1
      fi
      if [[ $EUID -ne 0 ]]; then
        log_fail "Update in install mode requires root. Re-run with: sudo ${SCRIPT_NAME} --update"
        return 1
      fi
      log_step "Updating vm-init installation under /opt/vm-init"
      if [[ -n "$latest" ]]; then
        log_info "Latest available release: ${latest#v}"
        # Avoid leaking vm-init's own VM_INIT_VERSION (e.g., "1.1.0") into
        # install.sh, and pin the exact release tag (e.g., "v1.1.0").
        env -u VM_INIT_VERSION bash "$installer" --prefix /opt/vm-init --version "$latest"
      else
        # Fallback to installer default ("latest"), without inheriting local
        # VM_INIT_VERSION that is not a release tag.
        env -u VM_INIT_VERSION bash "$installer" --prefix /opt/vm-init
      fi
      return $?
      ;;
    bundled_single_file)
      echo ""
      echo -e "${_C_BOLD}vm-init update${_C_RESET} (${_C_CYAN}single-file mode${_C_RESET})"
      [[ -n "$latest" ]] && echo -e "  ${_C_DIM}Latest:${_C_RESET} ${_C_BOLD}${latest#v}${_C_RESET}"
      echo -e "  Download: ${_C_CYAN}${VM_INIT_UPDATE_DOWNLOAD_URL}${_C_RESET}"
      echo -e "  Replace the current binary (example):"
      echo -e "    ${_C_CYAN}curl -fsSL ${VM_INIT_UPDATE_DOWNLOAD_URL} -o /usr/local/sbin/vm-init${_C_RESET}"
      echo -e "    ${_C_CYAN}sudo chmod +x /usr/local/sbin/vm-init${_C_RESET}"
      return 0
      ;;
    local_checkout|*)
      echo ""
      echo -e "${_C_BOLD}vm-init update${_C_RESET} (${_C_CYAN}local checkout mode${_C_RESET})"
      [[ -n "$latest" ]] && echo -e "  ${_C_DIM}Latest:${_C_RESET} ${_C_BOLD}${latest#v}${_C_RESET}"
      echo -e "  Download: ${_C_CYAN}${VM_INIT_UPDATE_DOWNLOAD_URL}${_C_RESET}"
      echo -e "  Update this checkout with git or install the managed release under /opt/vm-init:"
      echo -e "    ${_C_CYAN}curl -fsSL https://raw.githubusercontent.com/${VM_INIT_UPDATE_REPO}/main/scripts/install.sh | sudo bash${_C_RESET}"
      return 0
      ;;
  esac
}

VM_INIT_RUN_MODE="$(detect_run_mode)"

export VM_INIT_FORCE=0
export VM_INIT_VERBOSE=0
export VM_INIT_NO_LOG=0
export VM_INIT_DRY_RUN=0
VM_INIT_DO_UPDATE=0
VM_INIT_LIST_MODULES=0
VM_INIT_WRITE_DEFAULT_CONFIG=0
VM_INIT_ONLY=""
VM_INIT_SKIP=""
LOG_FILE=""

VM_INIT_START_TS=$(date +%s)

# Single source of truth: section:module_file:entry_func
VM_INIT_MODULES=(
  "apt:apt.sh:install_apt"
  "ufw:ufw.sh:install_ufw"
  "fail2ban:fail2ban.sh:install_fail2ban"
  "dns:dns.sh:install_dns"
  "docker:docker.sh:install_docker"
  "python:python.sh:install_python"
  "github_tools:github-tools.sh:install_github_tools"
  "github_releases:github-releases.sh:install_github_releases"
  "shell:shell.sh:install_shell"
)

_usage_opt() {
  local flag="$1" desc="$2"
  printf "    ${_C_BOLD}%-22s${_C_RESET} %s\n" "$flag" "$desc"
}

_usage_example() {
  local comment="$1" cmd="$2"
  echo -e "  ${_C_DIM}# ${comment}${_C_RESET}"
  echo -e "  ${_C_CYAN}${cmd}${_C_RESET}"
  echo ""
}

usage() {
  echo -e "${_C_BOLD}vm-init${_C_RESET} ${_C_CYAN}${VM_INIT_VERSION}${_C_RESET} ${_C_DIM}—${_C_RESET} Config-driven Ubuntu machine setup"

  print_help_section "Usage:"
  echo -e "  sudo ${SCRIPT_NAME} [options]"

  print_help_section "Options:"
  echo -e "  ${_C_DIM}Selection${_C_RESET}"
  _usage_opt "--config, -c <path>"    "Config file (default: /etc/vm-init/vm-init.yml, then ./vm-init.yml, then sibling vm-init.yml)"
  _usage_opt "--only <list>"      "Comma-separated module names to run (others skipped)"
  _usage_opt "--skip <list>"      "Comma-separated module names to exclude"
  _usage_opt "--list-modules, -l"     "Print modules with enabled/disabled state and exit"
  _usage_opt "--write-default-config, -w" "Write embedded default to ./vm-init.yml in the current directory and exit"
  echo ""
  echo -e "  ${_C_DIM}Execution${_C_RESET}"
  _usage_opt "--dry-run"          "Preview: show each module's actions, no changes"
  _usage_opt "--update, -u"           "Update vm-init (mode-aware behavior)"
  _usage_opt "--force, -f"            "Reinstall/overwrite all tools"
  _usage_opt "--verbose"          "Show full command output (default: quiet)"
  echo ""
  echo -e "  ${_C_DIM}Logging${_C_RESET}"
  _usage_opt "--no-log"           "Don't mirror output to a log file"
  _usage_opt "--log-file <path>"  "Write log to <path> (default: /var/log/vm-init-<ts>.log)"
  echo ""
  echo -e "  ${_C_DIM}Info${_C_RESET}"
  _usage_opt "--version"          "Print version and exit"
  _usage_opt "--help, -h"         "Show this help"

  print_help_section "Modules:"
  echo "  apt, ufw, fail2ban, dns, docker, python, github_tools, github_releases, shell"

  print_help_section "Status legend:"
  print_status_legend

  print_help_section "Examples:"
  _usage_example "Default full run"                                  "sudo ${SCRIPT_NAME}"
  _usage_example "Preview what would happen without changing system" "${SCRIPT_NAME} --dry-run"
  _usage_example "Show which modules are enabled in the config"      "${SCRIPT_NAME} --list-modules"
  _usage_example "Rerun only DNS after a failure"                    "sudo ${SCRIPT_NAME} --only dns"
  _usage_example "Skip slow modules for quick first-boot provisioning" "sudo ${SCRIPT_NAME} --skip docker,github_releases"
  _usage_example "Reinstall everything, verbose"                     "sudo ${SCRIPT_NAME} --force --verbose"

  print_help_section "Recovery:"
  echo -e "  If DNS is broken after provisioning, run:"
  echo -e "    ${_C_CYAN}sudo modules/recover-dns.sh --with-fallback${_C_RESET}"
  echo -e "  (also installed as ${_C_CYAN}/usr/local/sbin/vm-init-recover-dns${_C_RESET} when the DNS module runs)"

  echo ""
  echo -e "${_C_DIM}Environment: NO_COLOR / VM_INIT_NO_COLOR disable color, VM_INIT_FORCE_COLOR=1 forces it.${_C_RESET}"
  echo ""
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config|-c)             CONFIG="$2"; CONFIG_EXPLICIT=1; shift 2 ;;
    --only)                   VM_INIT_ONLY="$2"; shift 2 ;;
    --skip)                   VM_INIT_SKIP="$2"; shift 2 ;;
    --dry-run)                export VM_INIT_DRY_RUN=1; shift ;;
    --update|-u)             VM_INIT_DO_UPDATE=1; shift ;;
    --list-modules|-l)       VM_INIT_LIST_MODULES=1; shift ;;
    --write-default-config|-w) VM_INIT_WRITE_DEFAULT_CONFIG=1; shift ;;
    --force|-f)              export VM_INIT_FORCE=1; shift ;;
    --verbose)                export VM_INIT_VERBOSE=1; shift ;;
    --no-log)                 export VM_INIT_NO_LOG=1; shift ;;
    --log-file)               LOG_FILE="$2"; shift 2 ;;
    --version)                echo "vm-init ${VM_INIT_VERSION}"; exit 0 ;;
    --help|-h)                usage; exit 0 ;;
    *)                        echo -e "${_C_RED}${_SYM_FAIL}${_C_RESET} Unknown option: ${_C_BOLD}$1${_C_RESET}" >&2; echo "" >&2; usage >&2; exit 1 ;;
  esac
done

# Validate --only / --skip names against known modules
validate_module_filters() {
  local valid_names=""
  local spec
  for spec in "${VM_INIT_MODULES[@]}"; do
    valid_names+="${spec%%:*},"
  done

  local list name
  for list in "$VM_INIT_ONLY" "$VM_INIT_SKIP"; do
    [[ -z "$list" ]] && continue
    IFS=',' read -ra names <<< "$list"
    for name in "${names[@]}"; do
      [[ -z "$name" ]] && continue
      if ! [[ ",$valid_names" == *",$name,"* ]]; then
        log_fail "Unknown module: '$name' (valid: ${valid_names%,})"
        return 1
      fi
    done
  done
}

if ! validate_module_filters; then
  exit 1
fi

if [[ "$VM_INIT_DO_UPDATE" == "1" ]]; then
  if ! run_update_cmd; then
    exit 1
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# --write-default-config: materialize embedded or sibling default to
# /etc/vm-init/vm-init.yml so users can edit it in place.
# ---------------------------------------------------------------------------

write_default_config_cmd() {
  local target
  target="$(pwd)/vm-init.yml"
  if [[ -f "$target" ]]; then
    log_fail "${target} already exists — remove or back up first"
    return 1
  fi
  if ! declare -F _emit_default_config >/dev/null 2>&1; then
    log_fail "Default config emitter is not available in this build"
    return 1
  fi
  if ! _emit_default_config > "$target" 2>/dev/null; then
    rm -f "$target"
    log_fail "Could not write ${target} (check directory permissions)"
    return 1
  fi
  chmod 644 "$target" 2>/dev/null || true
  log_ok "Wrote default config to ${_C_CYAN}${target}${_C_RESET}"
  echo ""
  echo -e "  ${_C_BOLD}Next:${_C_RESET} edit ${_C_CYAN}${target}${_C_RESET}, then run:"
  echo -e "    ${_C_CYAN}sudo ${SCRIPT_NAME} --config ${target}${_C_RESET}"
  echo -e "  Or move it to a standard location that ${SCRIPT_NAME} auto-picks-up:"
  echo -e "    ${_C_CYAN}sudo install -Dm 0644 ${target} /etc/vm-init/vm-init.yml${_C_RESET}"
  return 0
}

if [[ "$VM_INIT_WRITE_DEFAULT_CONFIG" == "1" ]]; then
  write_default_config_cmd
  exit $?
fi

# ---------------------------------------------------------------------------
# Embedded-config fallback: when the user did not pass --config and no
# on-disk default exists, single-file bundles materialize the inlined YAML
# to a temporary file so --list-modules and --dry-run work out of the box.
# ---------------------------------------------------------------------------

VM_INIT_EMBEDDED_CONFIG_TMP=""
_cleanup_embedded_config() {
  if [[ -n "${VM_INIT_EMBEDDED_CONFIG_TMP:-}" && -f "${VM_INIT_EMBEDDED_CONFIG_TMP}" ]]; then
    rm -f "$VM_INIT_EMBEDDED_CONFIG_TMP"
  fi
}

if [[ "$CONFIG_EXPLICIT" != "1" && ! -f "$CONFIG" ]] \
   && declare -F _emit_default_config >/dev/null 2>&1; then
  VM_INIT_EMBEDDED_CONFIG_TMP=$(mktemp 2>/dev/null || true)
  if [[ -n "$VM_INIT_EMBEDDED_CONFIG_TMP" ]] \
     && _emit_default_config > "$VM_INIT_EMBEDDED_CONFIG_TMP" 2>/dev/null \
     && [[ -s "$VM_INIT_EMBEDDED_CONFIG_TMP" ]]; then
    CONFIG="$VM_INIT_EMBEDDED_CONFIG_TMP"
    trap _cleanup_embedded_config EXIT
  else
    rm -f "${VM_INIT_EMBEDDED_CONFIG_TMP:-}" 2>/dev/null || true
    VM_INIT_EMBEDDED_CONFIG_TMP=""
  fi
fi

module_excluded() {
  local section="$1"
  if [[ -n "$VM_INIT_ONLY" ]]; then
    if ! [[ ",$VM_INIT_ONLY," == *",$section,"* ]]; then
      return 0
    fi
  fi
  if [[ -n "$VM_INIT_SKIP" ]]; then
    if [[ ",$VM_INIT_SKIP," == *",$section,"* ]]; then
      return 0
    fi
  fi
  return 1
}

# ---------------------------------------------------------------------------
# --list-modules: early exit path
# ---------------------------------------------------------------------------

list_modules_cmd() {
  if [[ ! -f "$CONFIG" ]]; then
    log_fail "Config file not found: ${CONFIG}"
    return 1
  fi
  if ! command -v yq >/dev/null 2>&1; then
    log_fail "yq not found — install it or run a full 'sudo $0' which auto-installs it"
    return 1
  fi

  local on_count=0 off_count=0 filtered_count=0
  echo ""
  echo -e "${_C_BOLD}Modules${_C_RESET} ${_C_DIM}in${_C_RESET} ${_C_CYAN}${CONFIG}${_C_RESET}"
  print_rule 60
  local spec section enabled selected
  for spec in "${VM_INIT_MODULES[@]}"; do
    section="${spec%%:*}"
    enabled=$(yq_get ".${section}.enabled" true "$CONFIG")
    if module_excluded "$section"; then
      selected="filtered"
      filtered_count=$((filtered_count + 1))
    elif [[ "$enabled" == "true" ]]; then
      selected="on"
      on_count=$((on_count + 1))
    else
      selected="off"
      off_count=$((off_count + 1))
    fi
    case "$selected" in
      on)
        printf "  ${_C_GREEN}%-5s${_C_RESET} ${_C_BOLD}%-18s${_C_RESET} ${_C_DIM}%s${_C_RESET}\n" \
          "[on]" "$section" "enabled in config"
        ;;
      off)
        printf "  ${_C_DIM}%-5s %-18s %s${_C_RESET}\n" \
          "[off]" "$section" "disabled in config"
        ;;
      filtered)
        printf "  ${_C_YELLOW}%-5s${_C_RESET} %-18s ${_C_DIM}%s${_C_RESET}\n" \
          "[--]" "$section" "excluded by --only/--skip"
        ;;
    esac
  done
  print_rule 60
  printf "  ${_C_GREEN}on${_C_RESET}: %d   ${_C_DIM}off${_C_RESET}: %d   ${_C_YELLOW}filtered${_C_RESET}: %d\n" \
    "$on_count" "$off_count" "$filtered_count"
}

if [[ "$VM_INIT_LIST_MODULES" == "1" ]]; then
  list_modules_cmd
  exit $?
fi

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------

if [[ "$VM_INIT_NO_LOG" != "1" && "$VM_INIT_DRY_RUN" != "1" ]]; then
  if [[ -z "$LOG_FILE" ]]; then
    LOG_FILE="/var/log/vm-init-$(date +%Y%m%d-%H%M%S).log"
  fi
  if mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null && : > "$LOG_FILE" 2>/dev/null; then
    exec > >(tee -a "$LOG_FILE") 2>&1
  else
    LOG_FILE=""
  fi
fi

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

print_banner() {
  local title="vm-init v${VM_INIT_VERSION}"
  local tagline="Config-driven Ubuntu machine setup"
  local w=44
  local in_w=$((w - 4))
  local h v tl tr bl br
  if [[ "${_VM_INIT_USE_UNICODE:-0}" == "1" ]]; then
    h="═" v="║" tl="╔" tr="╗" bl="╚" br="╝"
  else
    h="=" v="|" tl="+" tr="+" bl="+" br="+"
  fi
  local bar="" i
  for ((i = 0; i < w; i++)); do bar+="$h"; done

  echo ""
  echo -e "${_C_BOLD}${_C_CYAN}  ${tl}${bar}${tr}${_C_RESET}"
  printf  "${_C_BOLD}${_C_CYAN}  ${v}${_C_RESET}  ${_C_BOLD}${_C_BRIGHT_CYAN}%-${in_w}s${_C_RESET}  ${_C_BOLD}${_C_CYAN}${v}${_C_RESET}\n" "$title"
  printf  "${_C_BOLD}${_C_CYAN}  ${v}${_C_RESET}  ${_C_DIM}%-${in_w}s${_C_RESET}  ${_C_BOLD}${_C_CYAN}${v}${_C_RESET}\n" "$tagline"
  echo -e "${_C_BOLD}${_C_CYAN}  ${bl}${bar}${br}${_C_RESET}"
}

print_banner

print_update_notice_if_needed

if [[ "$VM_INIT_DRY_RUN" == "1" ]]; then
  echo ""
  echo -e "  ${_C_YELLOW}${_C_BOLD}${_SYM_WARN} DRY RUN${_C_RESET} ${_C_YELLOW}— no changes will be made${_C_RESET}"
fi

echo ""

# ---------------------------------------------------------------------------
# Environment checks (skipped in dry-run)
# ---------------------------------------------------------------------------

if [[ "$VM_INIT_DRY_RUN" != "1" ]]; then
  if [[ $EUID -ne 0 ]]; then
    log_fail "Run this script as root (sudo $0)"
    exit 1
  fi

  if [[ ! -f /etc/os-release ]] || ! grep -qi ubuntu /etc/os-release; then
    log_fail "This script only supports Ubuntu"
    exit 1
  fi
fi

if [[ ! -f "$CONFIG" ]]; then
  log_fail "Config file not found: ${CONFIG}"
  exit 1
fi

echo -e "${_C_BOLD}Run configuration${_C_RESET}"
print_rule 44
print_kv "Config"   "${_C_CYAN}${CONFIG}${_C_RESET}"
[[ -n "${LOG_FILE:-}"     ]] && print_kv "Log"     "${_C_CYAN}${LOG_FILE}${_C_RESET}"
[[ -n "$VM_INIT_ONLY"     ]] && print_kv "Only"    "${_C_BOLD}${VM_INIT_ONLY}${_C_RESET}"
[[ -n "$VM_INIT_SKIP"     ]] && print_kv "Skip"    "${_C_BOLD}${VM_INIT_SKIP}${_C_RESET}"
[[ "$VM_INIT_FORCE"   == "1" ]] && print_kv "Force"   "${_C_YELLOW}${_C_BOLD}ON${_C_RESET}"
[[ "$VM_INIT_VERBOSE" == "1" ]] && print_kv "Verbose" "${_C_YELLOW}${_C_BOLD}ON${_C_RESET}"
[[ "$VM_INIT_DRY_RUN" == "1" ]] && print_kv "Dry-run" "${_C_YELLOW}${_C_BOLD}ON${_C_RESET}"

# ---------------------------------------------------------------------------
# yq bootstrap (skipped in dry-run)
# ---------------------------------------------------------------------------

if [[ "$VM_INIT_DRY_RUN" != "1" ]]; then
  if ! command -v yq >/dev/null 2>&1; then
    log_step "Installing yq"
    sys_arch=$(dpkg --print-architecture)
    yq_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${sys_arch}"
    if ! run_quiet download_file "$yq_url" /usr/local/bin/yq; then
      log_fail "Failed to download yq from ${yq_url}"
      exit 1
    fi
    chmod +x /usr/local/bin/yq
    log_ok "yq installed"
  fi
else
  if ! command -v yq >/dev/null 2>&1; then
    log_fail "yq not found (dry-run cannot auto-install it). Install yq and retry."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Config validation
# ---------------------------------------------------------------------------

validate_config() {
  local errors=0
  local val i count

  log_step "Validating config"

  if [[ "$(yq_get '.dns.enabled' true "$CONFIG")" == "true" ]]; then
    val=$(yq_get '.dns.server' "" "$CONFIG")
    if [[ -n "$val" ]]; then
      if [[ "$val" != https://* && "$val" != tls://* ]]; then
        log_fail "dns.server must start with https:// (DoH) or tls:// (DoT): got '$val'"
        errors=$((errors + 1))
      fi
    fi
    val=$(yq_get '.dns.listen_port' 5353 "$CONFIG")
    if ! [[ "$val" =~ ^[0-9]+$ ]] || (( val < 1 || val > 65535 )); then
      log_fail "dns.listen_port must be an integer in 1-65535: got '$val'"
      errors=$((errors + 1))
    fi
  fi

  if [[ "$(yq_get '.ufw.enabled' true "$CONFIG")" == "true" ]]; then
    for dir in incoming outgoing; do
      val=$(yq_get ".ufw.defaults.${dir}" "" "$CONFIG")
      if [[ -n "$val" ]]; then
        case "$val" in
          allow|deny|reject) ;;
          *)
            log_fail "ufw.defaults.${dir} must be allow|deny|reject: got '$val'"
            errors=$((errors + 1))
            ;;
        esac
      fi
    done
  fi

  if [[ "$(yq_get '.fail2ban.enabled' true "$CONFIG")" == "true" ]]; then
    val=$(yq_get '.fail2ban.maxretry' 5 "$CONFIG")
    if ! [[ "$val" =~ ^[0-9]+$ ]] || (( val < 1 )); then
      log_fail "fail2ban.maxretry must be a positive integer: got '$val'"
      errors=$((errors + 1))
    fi
    val=$(yq_get '.fail2ban.banaction' "auto" "$CONFIG")
    case "$val" in
      ""|*" "*)
        log_fail "fail2ban.banaction must be a simple action name (no spaces): got '$val'"
        errors=$((errors + 1))
        ;;
    esac
  fi

  if [[ "$(yq_get '.github_releases.enabled' true "$CONFIG")" == "true" ]]; then
    count=$(yq '.github_releases.generic // [] | length' "$CONFIG")
    for ((i = 0; i < count; i++)); do
      for field in repo binary asset_pattern; do
        val=$(yq_get ".github_releases.generic[$i].${field}" "" "$CONFIG")
        if [[ -z "$val" ]]; then
          log_fail "github_releases.generic[$i].${field} is required"
          errors=$((errors + 1))
        fi
      done
    done
  fi

  if [[ "$(yq_get '.shell.enabled' true "$CONFIG")" == "true" ]]; then
    val=$(yq_get '.shell.default_shell' "" "$CONFIG")
    if [[ -n "$val" ]]; then
      case "$val" in
        */*|*' '*)
          log_fail "shell.default_shell must be a plain binary name: got '$val'"
          errors=$((errors + 1))
          ;;
      esac
    fi
  fi

  if (( errors > 0 )); then
    log_fail "Config validation failed with ${errors} error(s)"
    return 1
  fi

  log_ok "Config valid"
  return 0
}

if ! validate_config; then
  exit 1
fi

# ---------------------------------------------------------------------------
# Dry-run preview for a module
# ---------------------------------------------------------------------------

_dry_run_line() {
  echo -e "  ${_C_CYAN}${_SYM_BULLET}${_C_RESET} $*"
}

dry_run_preview() {
  local section="$1"
  local val list

  case "$section" in
    apt)
      list=$(yq '.apt.packages | to_entries | .[].value | .[]' "$CONFIG" 2>/dev/null | sort -u | paste -sd' ' -)
      _dry_run_line "Would install APT packages: ${_C_BOLD}${list:-<none>}${_C_RESET}"
      ;;
    ufw)
      local incoming outgoing rules
      incoming=$(yq '.ufw.defaults.incoming // "deny"' "$CONFIG")
      outgoing=$(yq '.ufw.defaults.outgoing // "allow"' "$CONFIG")
      rules=$(yq '.ufw.allow[]? // ""' "$CONFIG" | paste -sd',' -)
      _dry_run_line "Would configure ufw: incoming=${_C_BOLD}${incoming}${_C_RESET}, outgoing=${_C_BOLD}${outgoing}${_C_RESET}, allow=[${_C_BOLD}${rules}${_C_RESET}]"
      ;;
    fail2ban)
      local f2b_bantime f2b_maxretry f2b_banaction f2b_jails
      f2b_bantime=$(yq_get '.fail2ban.bantime' "1h" "$CONFIG")
      f2b_maxretry=$(yq_get '.fail2ban.maxretry' "5" "$CONFIG")
      f2b_banaction=$(yq_get '.fail2ban.banaction' "auto" "$CONFIG")
      f2b_jails=$(yq '.fail2ban.jails // {} | to_entries | .[] | select(.value.enabled == true) | .key' "$CONFIG" 2>/dev/null | paste -sd',' -)
      _dry_run_line "Would install ${_C_BOLD}fail2ban${_C_RESET} and enable its service"
      _dry_run_line "Policy:       bantime=${_C_BOLD}${f2b_bantime}${_C_RESET}, maxretry=${_C_BOLD}${f2b_maxretry}${_C_RESET}, banaction=${_C_BOLD}${f2b_banaction}${_C_RESET}"
      _dry_run_line "Active jails: ${_C_BOLD}${f2b_jails:-<none>}${_C_RESET}"
      ;;
    dns)
      local server port
      server=$(yq '.dns.server // "<unset>"' "$CONFIG")
      port=$(yq '.dns.listen_port // 5353' "$CONFIG")
      _dry_run_line "Would install dnsproxy and configure systemd-resolved"
      _dry_run_line "Upstream:    ${_C_BOLD}${server}${_C_RESET}"
      _dry_run_line "Listen port: ${_C_BOLD}${port}${_C_RESET}"
      ;;
    docker)
      _dry_run_line "Would install ${_C_BOLD}docker-ce${_C_RESET}, docker-ce-cli, containerd.io, buildx, compose plugin"
      _dry_run_line "Would add first human user to the ${_C_BOLD}docker${_C_RESET} group"
      ;;
    python)
      list=$(yq '.python.tools[] // ""' "$CONFIG" 2>/dev/null | paste -sd',' -)
      _dry_run_line "Would install/upgrade pipx tools: ${_C_BOLD}${list:-<none>}${_C_RESET}"
      ;;
    github_tools)
      local gh act
      gh=$(yq_get '.github_tools.gh' true "$CONFIG")
      act=$(yq_get '.github_tools.act' true "$CONFIG")
      _dry_run_line "Would install: gh=${_C_BOLD}${gh}${_C_RESET}, act=${_C_BOLD}${act}${_C_RESET}"
      ;;
    github_releases)
      local generic custom
      generic=$(yq '.github_releases.generic[]?.binary // ""' "$CONFIG" 2>/dev/null | paste -sd',' -)
      custom=$(yq '.github_releases.custom // {} | to_entries | .[] | select(.value == true) | .key' "$CONFIG" 2>/dev/null | paste -sd',' -)
      _dry_run_line "Would install generic binaries: ${_C_BOLD}${generic:-<none>}${_C_RESET}"
      _dry_run_line "Would install custom tools:     ${_C_BOLD}${custom:-<none>}${_C_RESET}"
      ;;
    shell)
      local default_shell aliases
      default_shell=$(yq_get '.shell.default_shell' "fish" "$CONFIG")
      aliases=$(yq '.shell.aliases // {} | keys | .[]' "$CONFIG" 2>/dev/null | paste -sd',' -)
      _dry_run_line "Would set default shell: ${_C_BOLD}${default_shell}${_C_RESET}"
      _dry_run_line "Would configure aliases: ${_C_BOLD}${aliases:-<none>}${_C_RESET}"
      ;;
    *)
      _dry_run_line "${_C_DIM}(no preview available for ${section})${_C_RESET}"
      ;;
  esac
  val=$(yq_get ".${section}.enabled" true "$CONFIG")
  if [[ "$val" != "true" ]]; then
    echo -e "  ${_C_DIM}(module is disabled in config — would not run)${_C_RESET}"
  fi
}

# ---------------------------------------------------------------------------
# Module runner with status tracking
# ---------------------------------------------------------------------------

declare -a VM_INIT_MODULE_NAMES=()
declare -a VM_INIT_MODULE_STATUS=()
declare -a VM_INIT_MODULE_DETAIL=()

record_module_status() {
  VM_INIT_MODULE_NAMES+=("$1")
  VM_INIT_MODULE_STATUS+=("$2")
  VM_INIT_MODULE_DETAIL+=("$3")
}

run_module() {
  local section="$1" module_file="$2" entry_func="$3" progress="${4:-}"
  local enabled rc=0 pre_warn new_warns

  log_section "${section}" "${progress}"

  if module_excluded "$section"; then
    log_skip "excluded by --only/--skip"
    record_module_status "$section" "skipped" "excluded by filter"
    return 0
  fi

  enabled=$(yq_get ".${section}.enabled" true "$CONFIG")
  if [[ "$enabled" != "true" ]]; then
    log_skip "disabled in config"
    record_module_status "$section" "skipped" "disabled in config"
    return 0
  fi

  if [[ "$VM_INIT_DRY_RUN" == "1" ]]; then
    dry_run_preview "$section"
    record_module_status "$section" "ok" "dry-run"
    return 0
  fi

  pre_warn="${VM_INIT_WARN_COUNT:-0}"

  if ! declare -F "$entry_func" >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "${MODULES_DIR}/${module_file}"
  fi
  set +e
  run_with_errexit "$entry_func"
  rc=$?
  set -e

  new_warns=$(( ${VM_INIT_WARN_COUNT:-0} - pre_warn ))

  if (( rc != 0 )); then
    record_module_status "$section" "failed" "exit ${rc}"
  elif (( new_warns > 0 )); then
    record_module_status "$section" "warned" "${new_warns} warning(s)"
  else
    record_module_status "$section" "ok" ""
  fi
}

VM_INIT_TOTAL_MODULES=${#VM_INIT_MODULES[@]}
VM_INIT_MODULE_INDEX=0
for module_spec in "${VM_INIT_MODULES[@]}"; do
  IFS=':' read -r section module_file entry_func <<< "$module_spec"
  VM_INIT_MODULE_INDEX=$((VM_INIT_MODULE_INDEX + 1))
  run_module "$section" "$module_file" "$entry_func" "${VM_INIT_MODULE_INDEX}/${VM_INIT_TOTAL_MODULES}"
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_summary() {
  local i name status detail
  local ok=0 skip=0 warn=0 fail=0
  local total=${#VM_INIT_MODULE_NAMES[@]}
  local end_ts elapsed
  end_ts=$(date +%s)
  elapsed=$(( end_ts - VM_INIT_START_TS ))

  echo ""
  echo -e "${_C_BOLD}${_C_MAGENTA}━━━ Summary ━━━${_C_RESET}"
  for ((i = 0; i < total; i++)); do
    name="${VM_INIT_MODULE_NAMES[$i]}"
    status="${VM_INIT_MODULE_STATUS[$i]}"
    detail="${VM_INIT_MODULE_DETAIL[$i]}"
    case "$status" in
      ok)
        ok=$((ok + 1))
        if [[ -n "$detail" ]]; then
          printf "  ${_C_GREEN}%-4s${_C_RESET} %-18s ${_C_DIM}(%s)${_C_RESET}\n" \
            "${_SYM_OK}" "$name" "$detail"
        else
          printf "  ${_C_GREEN}%-4s${_C_RESET} %-18s\n" "${_SYM_OK}" "$name"
        fi
        ;;
      skipped)
        skip=$((skip + 1))
        printf "  ${_C_DIM}%-4s %-18s (%s)${_C_RESET}\n" \
          "${_SYM_SKIP}" "$name" "$detail"
        ;;
      warned)
        warn=$((warn + 1))
        printf "  ${_C_YELLOW}%-4s${_C_RESET} %-18s ${_C_YELLOW}%s${_C_RESET}\n" \
          "${_SYM_WARN}" "$name" "$detail"
        ;;
      failed)
        fail=$((fail + 1))
        printf "  ${_C_RED}%-4s${_C_RESET} %-18s ${_C_RED}%s${_C_RESET}\n" \
          "${_SYM_FAIL}" "$name" "$detail"
        ;;
    esac
  done

  echo ""
  print_rule 60
  printf "  ${_C_GREEN}ok${_C_RESET}: %d   ${_C_DIM}skipped${_C_RESET}: %d   ${_C_YELLOW}warned${_C_RESET}: %d   ${_C_RED}failed${_C_RESET}: %d   ${_C_DIM}elapsed: %s${_C_RESET}\n" \
    "$ok" "$skip" "$warn" "$fail" "$(format_duration "$elapsed")"

  [[ -n "${LOG_FILE:-}" ]] && printf "  ${_C_DIM}Log:${_C_RESET} ${_C_CYAN}%s${_C_RESET}\n" "${LOG_FILE}"

  if (( fail > 0 )); then
    echo ""
    echo -e "  ${_C_RED}${_C_BOLD}${_SYM_FAIL} Some modules failed.${_C_RESET} Review output above or in the log file."
    return 1
  fi

  if [[ "$VM_INIT_DRY_RUN" == "1" ]]; then
    echo ""
    echo -e "  ${_C_YELLOW}${_SYM_INFO} Dry run complete${_C_RESET} — no changes made."
    return 0
  fi

  if (( warn > 0 )); then
    echo ""
    echo -e "  ${_C_YELLOW}${_SYM_WARN} Completed with warnings.${_C_RESET} Review output for details."
  fi

  echo ""
  log_done "Setup complete."
  echo -e "  Log out and back in, or run: ${_C_CYAN}${_C_BOLD}exec fish${_C_RESET}"
  return 0
}

if ! print_summary; then
  exit 1
fi
