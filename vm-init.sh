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
VM_INIT_RESOLVED_EXECUTABLE="${SCRIPT_DIR}/$(basename "$_self")"
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

# Shared configuration and transaction helpers are also inlined in bundles.
if ! declare -F check_config_tools >/dev/null; then
  # shellcheck source=modules/_config.sh
  source "${MODULES_DIR}/_config.sh"
fi
if ! declare -F snapshot_paths >/dev/null; then
  # shellcheck source=modules/_safety.sh
  source "${MODULES_DIR}/_safety.sh"
fi
if ! declare -F recover_dns_main >/dev/null; then
  # shellcheck source=modules/_recovery.sh
  source "${MODULES_DIR}/_recovery.sh"
fi
if ! declare -F setup_wizard >/dev/null; then
  # shellcheck source=modules/_actions.sh
  source "${MODULES_DIR}/_actions.sh"
fi
VM_INIT_EXECUTABLE="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

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
VM_INIT_CONFIG_ORIGIN="shipped default"
if [[ -f "/etc/vm-init/vm-init.yml" ]]; then
  CONFIG="/etc/vm-init/vm-init.yml"
  VM_INIT_CONFIG_ORIGIN="system configuration"
elif [[ -f "$(pwd)/vm-init.yml" ]]; then
  CONFIG="$(pwd)/vm-init.yml"
  VM_INIT_CONFIG_ORIGIN="current directory"
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
  if [[ -f "$SCRIPT_DIR/.vm-init-managed" || "$SCRIPT_DIR" == /opt/vm-init ]]; then
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

  echo -e "  ${_C_DIM}Tip:${_C_RESET} run ${_C_CYAN}sudo ${SCRIPT_NAME} --update${_C_RESET} to upgrade in place."
}

# In-place upgrade of a single-file bundle. Downloads the latest release
# asset, verifies its sha256 sidecar, and replaces the running binary on the
# same filesystem so the swap is atomic.
update_bundled_single_file() {
  local latest="${1:-}"
  local target target_dir tmpdir tmpbin bin_url sha_url rc=0

  target="$VM_INIT_RESOLVED_EXECUTABLE"
  if [[ ! -f "$target" ]]; then
    log_fail "Cannot locate current bundle at ${target}"
    return 1
  fi
  target_dir="$(dirname "$target")"

  if [[ $EUID -ne 0 && ! -w "$target_dir" ]]; then
    log_fail "Update requires root to write ${target_dir}. Re-run with: sudo ${SCRIPT_NAME} --update"
    return 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    log_fail "curl is required for in-place updates"
    return 1
  fi

  log_step "Updating vm-init bundle at ${target}"
  if [[ -n "$latest" ]]; then
    if ! is_version_newer "$latest" "$VM_INIT_VERSION"; then
      log_ok "Already at the latest version (${VM_INIT_VERSION})"
      return 0
    fi
    log_info "Upgrading ${VM_INIT_VERSION} → ${latest#v}"
  fi

  bin_url="${VM_INIT_UPDATE_DOWNLOAD_URL}"
  sha_url="${bin_url}.sha256"

  tmpdir=$(mktemp -d)
  tmpbin="${tmpdir}/vm-init"

  if ! run_quiet download_file "$bin_url" "$tmpbin"; then
    log_fail "Failed to download ${bin_url}"
    rm -rf "$tmpdir"
    return 1
  fi

  log_step "Verifying checksum"
  set +e
  verify_sha256 "$tmpbin" --from "$sha_url"
  rc=$?
  set -e
  case "$rc" in
    0) log_ok "Checksum matches" ;;
    1) log_fail "Checksum mismatch — refusing to install"; rm -rf "$tmpdir"; return 1 ;;
    2) log_fail "Could not download checksum from ${sha_url}"; rm -rf "$tmpdir"; return 1 ;;
    *) log_fail "Could not verify checksum (rc=${rc})"; rm -rf "$tmpdir"; return 1 ;;
  esac

  if ! bash -n "$tmpbin"; then
    log_fail "Downloaded bundle failed bash syntax check — refusing to install"
    rm -rf "$tmpdir"
    return 1
  fi

  chmod +x "$tmpbin"
  # Stage inside the target directory so the rename is atomic on the same fs.
  local staged
  staged="$(mktemp "${target_dir}/.vm-init.XXXXXX" 2>/dev/null || true)"
  if [[ -z "$staged" ]]; then
    log_fail "Cannot create staging file in ${target_dir}"
    rm -rf "$tmpdir"
    return 1
  fi
  if ! cp "$tmpbin" "$staged"; then
    log_fail "Failed to stage new bundle in ${target_dir}"
    rm -f "$staged"; rm -rf "$tmpdir"
    return 1
  fi
  # Preserve the existing binary's mode (falls back to 0755 if stat is unusable).
  local mode=""
  mode=$(stat -c '%a' "$target" 2>/dev/null || stat -f '%Lp' "$target" 2>/dev/null || echo "")
  [[ -n "$mode" ]] || mode="755"
  chmod "$mode" "$staged" 2>/dev/null || chmod 755 "$staged"
  if ! mv -f "$staged" "$target"; then
    log_fail "Failed to replace ${target}"
    rm -f "$staged"; rm -rf "$tmpdir"
    return 1
  fi

  rm -rf "$tmpdir"
  log_done "vm-init updated at ${target}"
  return 0
}

# Update a local git checkout by fast-forwarding the current branch to its
# upstream. Aborts (without touching the tree) when there are local changes,
# the branch is detached, or no upstream is configured.
update_local_checkout() {
  local repo="$SCRIPT_DIR" branch upstream before after

  if ! command -v git >/dev/null 2>&1; then
    log_fail "git is required to update a local checkout"
    return 1
  fi
  if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_fail "Not a git repository: ${repo}"
    return 1
  fi

  log_step "Updating local checkout at ${repo}"

  if ! git -C "$repo" diff-index --quiet HEAD -- 2>/dev/null \
     || [[ -n "$(git -C "$repo" ls-files --others --exclude-standard)" ]]; then
    log_fail "Working tree has uncommitted changes — commit or stash, then re-run"
    return 1
  fi
  branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
    log_fail "Detached HEAD — checkout a branch and re-run"
    return 1
  fi
  upstream="$(git -C "$repo" rev-parse --abbrev-ref "${branch}@{upstream}" 2>/dev/null || true)"
  if [[ -z "$upstream" ]]; then
    log_fail "Branch ${branch} has no upstream tracking branch (set one with 'git branch --set-upstream-to=...')"
    return 1
  fi

  before="$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown)"

  if ! run_quiet git -C "$repo" fetch --tags --quiet; then
    log_fail "git fetch failed"
    return 1
  fi
  if ! run_quiet git -C "$repo" merge --ff-only --quiet "$upstream"; then
    log_fail "Cannot fast-forward ${branch} to ${upstream} — diverged history; resolve manually"
    return 1
  fi

  after="$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown)"
  if [[ "$before" == "$after" ]]; then
    log_ok "Already up to date (${before:0:7})"
  else
    log_done "Local checkout updated: ${before:0:7} → ${after:0:7}"
  fi
  return 0
}

run_update_cmd() {
  local latest installer managed_bin=/usr/local/sbin managed_no_symlink=0
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
      if [[ -f "$SCRIPT_DIR/.vm-init-managed" ]]; then
        { read -r managed_bin; read -r managed_no_symlink; } < "$SCRIPT_DIR/.vm-init-managed" || return 1
      fi
      log_step "Updating vm-init installation under ${SCRIPT_DIR}"
      if [[ -n "$latest" ]]; then
        log_info "Latest available release: ${latest#v}"
        # Avoid leaking vm-init's own VM_INIT_VERSION (e.g., "1.1.0") into
        # install.sh, and pin the exact release tag (e.g., "v1.1.0").
        env -u VM_INIT_VERSION VM_INIT_BIN_DIR="$managed_bin" VM_INIT_NO_SYMLINK="$managed_no_symlink" \
          bash "$installer" --prefix "$SCRIPT_DIR" --version "$latest"
      else
        # Fallback to installer default ("latest"), without inheriting local
        # VM_INIT_VERSION that is not a release tag.
        env -u VM_INIT_VERSION VM_INIT_BIN_DIR="$managed_bin" VM_INIT_NO_SYMLINK="$managed_no_symlink" \
          bash "$installer" --prefix "$SCRIPT_DIR"
      fi
      return $?
      ;;
    bundled_single_file)
      update_bundled_single_file "$latest"
      return $?
      ;;
    local_checkout|*)
      update_local_checkout
      return $?
      ;;
  esac
}

VM_INIT_RUN_MODE="$(detect_run_mode)"

export VM_INIT_FORCE=0
export VM_INIT_NO_UPGRADE=0
export VM_INIT_VERBOSE=0
export VM_INIT_NO_LOG=0
export VM_INIT_DRY_RUN=0
VM_INIT_DO_UPDATE=0
VM_INIT_LIST_MODULES=0
VM_INIT_WRITE_DEFAULT_CONFIG=0
VM_INIT_VERIFY=0
VM_INIT_FAIL_FAST=0
VM_INIT_ONLY=""
VM_INIT_SKIP=""
VM_INIT_SETUP=0
VM_INIT_YES=0
VM_INIT_FEATURES=""
VM_INIT_JSON=0
VM_INIT_USER_OPTION=""
VM_INIT_ALL_USERS=0
VM_INIT_PREPARE=0
VM_INIT_REPAIR=""
VM_INIT_COMMAND=""
VM_INIT_RECOVERY_ARGS=()
VM_INIT_SETUP_TMP=""
VM_INIT_RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
VM_INIT_CONFIG_FINGERPRINT=""
LOG_FILE=""
LOG_FILE_EXPLICIT=0

VM_INIT_START_TS=$(date +%s)

# Single source of truth: section:module_file:entry_func
VM_INIT_MODULES=(
  "apt:apt.sh:install_apt"
  "ufw:ufw.sh:install_ufw"
  "fail2ban:fail2ban.sh:install_fail2ban"
  "kernel:kernel.sh:install_kernel"
  "dns:dns.sh:install_dns"
  "docker:docker.sh:install_docker"
  "python:python.sh:install_python"
  "github_tools:github-tools.sh:install_github_tools"
  "github_releases:github-releases.sh:install_github_releases"
  "yazi:yazi.sh:install_yazi"
  "shell:shell.sh:install_shell"
)

# Comma-separated list of every registered module. Generated rather than
# written out by hand: the hardcoded list in --help had already drifted out of
# sync with VM_INIT_MODULES.
_module_names() {
  local spec out=""
  for spec in "${VM_INIT_MODULES[@]}"; do
    out+="${spec%%:*}, "
  done
  echo "${out%, }"
}

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
  echo -e "  sudo ${SCRIPT_NAME} [command] [options]"
  echo '  setup              Choose an account and features, preview, then apply'
  echo '  plan               Preview the selected configuration'
  echo '  apply              Apply configuration (also the default command)'
  echo '  status [--json]    Verify selected features and show their state'
  echo '  repair dns|failed  Restore DNS offline, or retry the last failed modules'
  echo '  confirm-firewall   Keep firewall changes from a new SSH session'
  echo '  prepare            Install configuration tools before the first preview'
  echo '  update             Update this vm-init installation'

  print_help_section "Options:"
  echo -e "  ${_C_DIM}Selection${_C_RESET}"
  _usage_opt "--config, -c <path>"    "Config file (default: /etc/vm-init/vm-init.yml, then ./vm-init.yml, then sibling vm-init.yml)"
  _usage_opt "--user <list>" "Accounts to configure (comma-separated; default: invoking sudo user)"
  _usage_opt "--all-users" "Explicitly configure root and every human account"
  _usage_opt "--features <list>" "setup features: shell,docker,python,tools"
  _usage_opt "--yes, -y" "Accept the setup plan for unattended setup"
  _usage_opt "--json" "Machine-readable status; diagnostics go to stderr"
  _usage_opt "--only <list>"      "Comma-separated module names to run (others skipped)"
  _usage_opt "--skip <list>"      "Comma-separated module names to exclude"
  _usage_opt "--list-modules, -l"     "Print modules with enabled/disabled state and exit"
  _usage_opt "--write-default-config, -w" "Write embedded default to ./vm-init.yml in the current directory and exit"
  echo ""
  echo -e "  ${_C_DIM}Execution${_C_RESET}"
  _usage_opt "--dry-run"          "Preview: show each module's actions, no changes"
  _usage_opt "--verify"           "Check that every enabled module is healthy; change nothing"
  _usage_opt "--fail-fast"        "Stop at the first failed module instead of continuing"
  _usage_opt "--update, -u"           "Update vm-init (mode-aware behavior)"
  _usage_opt "--force, -f"            "Reinstall/overwrite all tools"
  _usage_opt "--no-upgrade"           "Skip update checks for already-installed tools (default is upgrade-aware)"
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
  echo "  $(_module_names)"

  print_help_section "Status legend:"
  print_status_legend

  print_help_section "Examples:"
  _usage_example "Default minimal run"                               "sudo ${SCRIPT_NAME}"
  _usage_example "Preview what would happen without changing system" "${SCRIPT_NAME} --dry-run"
  _usage_example "Show which modules are enabled in the config"      "${SCRIPT_NAME} --list-modules"
  _usage_example "Rerun only DNS after a failure"                    "sudo ${SCRIPT_NAME} --only dns"
  _usage_example "Skip slow modules for quick first-boot provisioning" "sudo ${SCRIPT_NAME} --skip docker,github_releases"
  _usage_example "Reinstall everything, verbose"                     "sudo ${SCRIPT_NAME} --force --verbose"
  _usage_example "Check an already-provisioned machine is still healthy" "$(retry_command status)"

  print_help_section "Recovery:"
  echo -e "  If DNS is broken after provisioning, run:"
  echo -e "    ${_C_CYAN}sudo vm-init repair dns --with-fallback${_C_RESET}"
  echo -e "  From a source checkout, run: ${_C_CYAN}sudo modules/recover-dns.sh --with-fallback${_C_RESET}"

  echo ""
  echo -e "${_C_DIM}Environment: NO_COLOR / VM_INIT_NO_COLOR disable color, VM_INIT_FORCE_COLOR=1 forces it.${_C_RESET}"
  echo ""
}

require_option_value() {
  local flag="$1"
  local value="${2-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    log_fail "Missing value for ${flag}"
    echo "" >&2
    usage >&2
    exit 1
  fi
}

if [[ $# -gt 0 && "$1" != -* ]]; then
  VM_INIT_COMMAND="$1"; shift
  case "$VM_INIT_COMMAND" in
    setup) VM_INIT_SETUP=1 ;;
    plan) VM_INIT_DRY_RUN=1 ;;
    apply) ;;
    status) VM_INIT_VERIFY=1 ;;
    update) VM_INIT_DO_UPDATE=1 ;;
    prepare) VM_INIT_PREPARE=1 ;;
    confirm-firewall) VM_INIT_REPAIR=firewall ;;
    repair)
      VM_INIT_REPAIR="${1:-}"; [[ $# -eq 0 ]] || shift
      case "$VM_INIT_REPAIR" in dns|failed) ;; *) log_fail 'Usage: vm-init repair dns|failed'; exit 1 ;; esac ;;
    *) log_fail "Unknown command: $VM_INIT_COMMAND"; usage >&2; exit 1 ;;
  esac
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config|-c)             require_option_value "$1" "${2-}"; CONFIG="$2"; CONFIG_EXPLICIT=1; VM_INIT_CONFIG_ORIGIN="explicit --config"; shift 2 ;;
    --only)                   require_option_value "$1" "${2-}"; VM_INIT_ONLY="$2"; shift 2 ;;
    --skip)                   require_option_value "$1" "${2-}"; VM_INIT_SKIP="$2"; shift 2 ;;
    --dry-run)                export VM_INIT_DRY_RUN=1; shift ;;
    --verify)                 VM_INIT_VERIFY=1; shift ;;
    --fail-fast)              VM_INIT_FAIL_FAST=1; shift ;;
    --update|-u)             VM_INIT_DO_UPDATE=1; shift ;;
    --list-modules|-l)       VM_INIT_LIST_MODULES=1; shift ;;
    --write-default-config|-w) VM_INIT_WRITE_DEFAULT_CONFIG=1; shift ;;
    --force|-f)              export VM_INIT_FORCE=1; shift ;;
    --no-upgrade)             export VM_INIT_NO_UPGRADE=1; shift ;;
    --verbose)                export VM_INIT_VERBOSE=1; shift ;;
    --no-log)                 export VM_INIT_NO_LOG=1; shift ;;
    --log-file)               require_option_value "$1" "${2-}"; LOG_FILE="$2"; LOG_FILE_EXPLICIT=1; shift 2 ;;
    --user) require_option_value "$1" "${2-}"; VM_INIT_USER_OPTION="$2"; shift 2 ;;
    --all-users) VM_INIT_ALL_USERS=1; shift ;;
    --yes|-y) VM_INIT_YES=1; shift ;;
    --features) require_option_value "$1" "${2-}"; VM_INIT_FEATURES="$2"; shift 2 ;;
    --json) VM_INIT_JSON=1; shift ;;
    --prepare) VM_INIT_PREPARE=1; shift ;;
    --with-fallback) VM_INIT_RECOVERY_ARGS+=("$1"); shift ;;
    --iface|--fallback) require_option_value "$1" "${2-}"; VM_INIT_RECOVERY_ARGS+=("$1" "$2"); shift 2 ;;
    --version)                echo "vm-init ${VM_INIT_VERSION}"; exit 0 ;;
    --help|-h)                if [[ "$VM_INIT_REPAIR" == dns ]]; then recover_dns_usage; else usage; fi; exit 0 ;;
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

if [[ "$VM_INIT_VERIFY" == "1" && "$VM_INIT_DRY_RUN" == "1" ]]; then
  log_fail "--verify and --dry-run are mutually exclusive (--verify already changes nothing)"
  exit 1
fi

# Every mode conflict is rejected before writes, installs, update checks, or repair.
if (( VM_INIT_DO_UPDATE + VM_INIT_WRITE_DEFAULT_CONFIG + VM_INIT_LIST_MODULES + VM_INIT_PREPARE + VM_INIT_VERIFY + VM_INIT_DRY_RUN > 1 )) \
   || { [[ -n "$VM_INIT_REPAIR" ]] && (( VM_INIT_DO_UPDATE + VM_INIT_WRITE_DEFAULT_CONFIG + VM_INIT_LIST_MODULES + VM_INIT_PREPARE + VM_INIT_VERIFY + VM_INIT_DRY_RUN + VM_INIT_SETUP > 0 )); } \
   || { [[ "$VM_INIT_SETUP" == 1 ]] && (( VM_INIT_DO_UPDATE + VM_INIT_WRITE_DEFAULT_CONFIG + VM_INIT_LIST_MODULES + VM_INIT_PREPARE + VM_INIT_VERIFY > 0 )); }; then
  log_fail 'Execution modes are mutually exclusive; choose one command.'
  exit 1
fi
if [[ "$VM_INIT_ALL_USERS" == 1 && -n "$VM_INIT_USER_OPTION" ]]; then
  log_fail '--user and --all-users are mutually exclusive'; exit 1
fi
if [[ "$VM_INIT_JSON" == 1 && "$VM_INIT_VERIFY" != 1 ]]; then
  log_fail '--json is available with status or --verify'; exit 1
fi
if (( ${#VM_INIT_RECOVERY_ARGS[@]} > 0 )) && [[ "$VM_INIT_REPAIR" != dns ]]; then
  log_fail 'Recovery options require repair dns'; exit 1
fi
if [[ -n "$VM_INIT_FEATURES" && "$VM_INIT_SETUP" != 1 ]]; then log_fail '--features requires setup'; exit 1; fi
if [[ "$VM_INIT_JSON" == 1 ]]; then exec 3>&1; exec 1>&2; fi
if [[ "$VM_INIT_REPAIR" == dns ]]; then recover_dns_main "${VM_INIT_RECOVERY_ARGS[@]}"; exit $?; fi
if [[ "$VM_INIT_REPAIR" == firewall ]]; then
  [[ $EUID -eq 0 ]] || { log_fail 'Run as root: sudo vm-init confirm-firewall'; exit 1; }
  if ! declare -F confirm_firewall >/dev/null; then source "${MODULES_DIR}/ufw.sh"; fi
  confirm_firewall; exit $?
fi
if [[ "$VM_INIT_REPAIR" == failed ]]; then load_failed_run || exit 1; fi
if [[ "$VM_INIT_PREPARE" == 1 ]]; then
  [[ $EUID -eq 0 ]] || { log_fail 'Run as root: sudo vm-init prepare'; exit 1; }
  if [[ ! -f /etc/os-release ]] || ! grep -qi ubuntu /etc/os-release; then log_fail 'This script only supports Ubuntu'; exit 1; fi
  acquire_run_lock
  bootstrap_config_tools
  exit $?
fi

if [[ "$VM_INIT_DO_UPDATE" == "1" ]]; then
  if [[ $EUID -eq 0 ]]; then acquire_run_lock || exit 1; fi
  if ! run_update_cmd; then
    exit 1
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# --write-default-config: materialize embedded or sibling default to
# ./vm-init.yml so users can edit it before opting into modules.
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
  echo -e "    ${_C_CYAN}$(shell_command sudo "$VM_INIT_EXECUTABLE" apply --config "$target")${_C_RESET}"
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
VM_INIT_TALLY_FILE=""
VM_INIT_NOTES_FILE=""
_vm_init_cleanup() {
  [[ -z "${VM_INIT_SETUP_TMP:-}" ]] || rm -f "$VM_INIT_SETUP_TMP"
  if [[ -n "${VM_INIT_EMBEDDED_CONFIG_TMP:-}" && -f "${VM_INIT_EMBEDDED_CONFIG_TMP}" ]]; then
    rm -f "$VM_INIT_EMBEDDED_CONFIG_TMP"
  fi
  if [[ -n "${VM_INIT_TALLY_FILE:-}" && -f "${VM_INIT_TALLY_FILE}" ]]; then
    rm -f "$VM_INIT_TALLY_FILE"
  fi
  if [[ -n "${VM_INIT_NOTES_FILE:-}" && -f "${VM_INIT_NOTES_FILE}" ]]; then
    rm -f "$VM_INIT_NOTES_FILE"
  fi
}
trap _vm_init_cleanup EXIT

if [[ "$CONFIG_EXPLICIT" != "1" && ! -f "$CONFIG" ]] \
   && declare -F _emit_default_config >/dev/null 2>&1; then
  VM_INIT_EMBEDDED_CONFIG_TMP=$(mktemp 2>/dev/null || true)
  if [[ -n "$VM_INIT_EMBEDDED_CONFIG_TMP" ]] \
     && _emit_default_config > "$VM_INIT_EMBEDDED_CONFIG_TMP" 2>/dev/null \
     && [[ -s "$VM_INIT_EMBEDDED_CONFIG_TMP" ]]; then
    CONFIG="$VM_INIT_EMBEDDED_CONFIG_TMP"
    VM_INIT_CONFIG_ORIGIN="embedded default"
  else
    rm -f "${VM_INIT_EMBEDDED_CONFIG_TMP:-}" 2>/dev/null || true
    VM_INIT_EMBEDDED_CONFIG_TMP=""
  fi
fi

if [[ "$VM_INIT_SETUP" == 1 ]]; then setup_wizard || exit 1; fi
VM_INIT_SOURCE_CONFIG="$CONFIG"
if [[ "$CONFIG" == "$VM_INIT_EMBEDDED_CONFIG_TMP" ]]; then VM_INIT_SOURCE_CONFIG=""; fi
if [[ "$VM_INIT_SETUP" == 1 ]]; then VM_INIT_SOURCE_CONFIG=""; fi
if [[ "$VM_INIT_SOURCE_CONFIG" != "" && -f "$VM_INIT_SOURCE_CONFIG" ]]; then
  VM_INIT_SOURCE_CONFIG="$(cd "$(dirname "$VM_INIT_SOURCE_CONFIG")" && pwd)/$(basename "$VM_INIT_SOURCE_CONFIG")"
fi

# Tally file: per-tool outcomes (one of "installed", "upgraded", "current"
# per line) accumulated by log_installed/log_upgraded/log_current. Modules
# run inside subshells (run_with_errexit), so an env-passed file path is
# the simplest way to aggregate counts across them.
if [[ "$VM_INIT_DRY_RUN" != "1" && "$VM_INIT_VERIFY" != "1" ]]; then
  VM_INIT_TALLY_FILE=$(mktemp 2>/dev/null || true)
  if [[ -n "$VM_INIT_TALLY_FILE" ]]; then
    : > "$VM_INIT_TALLY_FILE"
    export VM_INIT_TALLY_FILE
  fi
fi

# Verification can also discover warnings and pending actions.
if [[ "$VM_INIT_DRY_RUN" != "1" ]]; then
  VM_INIT_NOTES_FILE=$(mktemp 2>/dev/null || true)
  if [[ -n "$VM_INIT_NOTES_FILE" ]]; then
    : > "$VM_INIT_NOTES_FILE"
    export VM_INIT_NOTES_FILE
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

validate_config() {
  local errors=0
  local val i count

  log_step "Validating config"
  validate_config_schema || return 1

  # Parse the file once up front. Without this, malformed YAML surfaces as a raw
  # yq trace from whichever lookup happens to run first.
  if ! yq -r '.' "$CONFIG" >/dev/null 2>&1; then
    log_fail "Config is not valid YAML: ${CONFIG}"
    yq -r '.' "$CONFIG" 2>&1 | head -5 >&2
    return 1
  fi

  # Unknown top-level keys are the silent failure mode of an opt-in config:
  # blocks default to enabled:false, so `github_release:` typed for
  # `github_releases:` disables the module with no diagnostic at all. Warn
  # rather than fail -- hand-edited configs may legitimately carry extra keys.
  local known="users," key spec
  for spec in "${VM_INIT_MODULES[@]}"; do
    known+="${spec%%:*},"
  done
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    if ! [[ ",$known" == *",$key,"* ]]; then
      log_warn "Unknown top-level config key '${key}' — ignored (typo? valid: ${known%,})"
    fi
  done < <(yq -r 'keys | .[]' "$CONFIG" 2>/dev/null)

  # APT package names end up in an unquoted expansion in apt.sh, and a name with
  # whitespace would silently split into two package requests.
  while IFS= read -r val; do
    [[ -z "$val" ]] && continue
    if ! [[ "$val" =~ ^[a-zA-Z0-9][a-zA-Z0-9+._-]*$ ]]; then
      log_fail "apt.packages contains an invalid package name: '$val'"
      errors=$((errors + 1))
    fi
  done < <(yq -r '.apt.packages // {} | to_entries | .[].value | .[]' "$CONFIG" 2>/dev/null)

  if [[ "$(yq_get '.python.enabled' false "$CONFIG")" == "true" ]]; then
    while IFS= read -r val; do
      [[ -z "$val" ]] && continue
      if ! [[ "$val" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        log_fail "python.tools contains an invalid tool name: '$val'"
        errors=$((errors + 1))
      fi
    done < <(yq -r '.python.tools // [] | .[]' "$CONFIG" 2>/dev/null)
  fi

  if [[ "$(yq_get '.dns.enabled' false "$CONFIG")" == "true" ]]; then
    val=$(yq_get '.dns.server' "" "$CONFIG")
    if [[ -n "$val" ]]; then
      if [[ "$val" != https://* && "$val" != tls://* ]]; then
        log_fail "dns.server must start with https:// (DoH) or tls:// (DoT): got '$val'"
        errors=$((errors + 1))
      fi
    fi
    if [[ "$val" == *[[:space:]]* ]]; then
      log_fail 'dns.server must not contain whitespace'; errors=$((errors + 1))
    fi
    val=$(yq_get '.dns.listen_address' 127.0.0.1 "$CONFIG")
    if ! python3 -c 'import ipaddress, sys; ipaddress.ip_address(sys.argv[1])' "$val" 2>/dev/null; then
      log_fail "dns.listen_address must be an IP address: $val"; errors=$((errors + 1))
    fi
    val=$(yq_get '.dns.listen_port' 5353 "$CONFIG")
    if ! [[ "$val" =~ ^[0-9]+$ ]] || (( 10#$val < 1 || 10#$val > 65535 )); then
      log_fail "dns.listen_port must be an integer in 1-65535: got '$val'"
      errors=$((errors + 1))
    fi
  fi

  if [[ "$(yq_get '.ufw.enabled' false "$CONFIG")" == "true" ]]; then
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

  if [[ "$(yq_get '.fail2ban.enabled' false "$CONFIG")" == "true" ]]; then
    val=$(yq_get '.fail2ban.maxretry' 5 "$CONFIG")
    if ! [[ "$val" =~ ^[0-9]+$ ]] || (( 10#$val < 1 )); then
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

  if [[ "$(yq_get '.github_releases.enabled' false "$CONFIG")" == "true" ]]; then
    count=$(yq -r '.github_releases.generic // [] | length' "$CONFIG")
    for ((i = 0; i < count; i++)); do
      for field in repo binary asset_pattern; do
        val=$(yq_get ".github_releases.generic[$i].${field}" "" "$CONFIG")
        if [[ -z "$val" ]]; then
          log_fail "github_releases.generic[$i].${field} is required"
          errors=$((errors + 1))
        fi
      done
      # The binary name is used as a path under /usr/local/bin and as a state
      # key, so it has to be a bare name.
      val=$(yq_get ".github_releases.generic[$i].binary" "" "$CONFIG")
      if [[ -n "$val" && ! "$val" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        log_fail "github_releases.generic[$i].binary must be a plain binary name: got '$val'"
        errors=$((errors + 1))
      fi
    done
  fi

  if [[ "$(yq_get '.shell.enabled' false "$CONFIG")" == "true" ]]; then
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
    enabled=$(yq_get ".${section}.enabled" false "$CONFIG")
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
  validate_config || exit 1
  list_modules_cmd
  exit $?
fi

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------

# --verify changes nothing, so it should not litter /var/log either. An
# explicit --log-file still wins.
if [[ "$VM_INIT_NO_LOG" != "1" && "$VM_INIT_DRY_RUN" != "1" ]] \
   && [[ "$VM_INIT_VERIFY" != "1" || "$LOG_FILE_EXPLICIT" == "1" ]]; then
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

if [[ "$VM_INIT_VERIFY" == "1" ]]; then
  echo ""
  echo -e "  ${_C_BLUE}${_C_BOLD}${_SYM_INFO} VERIFY${_C_RESET} ${_C_BLUE}— checking existing state, no changes will be made${_C_RESET}"
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
if [[ "$VM_INIT_SETUP" == 1 ]]; then
  print_kv 'Config' "Setup choices (save to ${VM_INIT_SETUP_DEST})"
elif [[ "$CONFIG" == "$VM_INIT_EMBEDDED_CONFIG_TMP" ]]; then
  print_kv 'Config' 'Embedded default'
else
  print_kv "Config" "${_C_CYAN}${CONFIG}${_C_RESET}"
fi
[[ -n "${LOG_FILE:-}"     ]] && print_kv "Log"     "${_C_CYAN}${LOG_FILE}${_C_RESET}"
[[ -n "$VM_INIT_ONLY"     ]] && print_kv "Only"    "${_C_BOLD}${VM_INIT_ONLY}${_C_RESET}"
[[ -n "$VM_INIT_SKIP"     ]] && print_kv "Skip"    "${_C_BOLD}${VM_INIT_SKIP}${_C_RESET}"
[[ "$VM_INIT_FORCE"      == "1" ]] && print_kv "Force"      "${_C_YELLOW}${_C_BOLD}ON${_C_RESET}"
[[ "$VM_INIT_NO_UPGRADE" == "1" ]] && print_kv "No-upgrade" "${_C_YELLOW}${_C_BOLD}ON${_C_RESET}"
[[ "$VM_INIT_VERBOSE"    == "1" ]] && print_kv "Verbose"    "${_C_YELLOW}${_C_BOLD}ON${_C_RESET}"
[[ "$VM_INIT_DRY_RUN"    == "1" ]] && print_kv "Dry-run"    "${_C_YELLOW}${_C_BOLD}ON${_C_RESET}"
[[ "$VM_INIT_VERIFY"     == "1" ]] && print_kv "Verify"     "${_C_BLUE}${_C_BOLD}ON${_C_RESET}"
[[ "$VM_INIT_FAIL_FAST"  == "1" ]] && print_kv "Fail-fast"  "${_C_YELLOW}${_C_BOLD}ON${_C_RESET}"

# ---------------------------------------------------------------------------
# Prepare dependencies only for an actual apply; all read-only commands refuse
# installation and explain the single preparation command.
if [[ "$VM_INIT_DRY_RUN" != 1 && "$VM_INIT_VERIFY" != 1 ]]; then
  acquire_run_lock || exit 1
  bootstrap_config_tools || exit 1
  log_step 'Checking for background apt/dpkg activity'
  # shellcheck disable=SC2119 # default system lock paths
  wait_apt_lock || exit 1
else
  check_config_tools || exit 1
fi


if ! validate_config; then
  exit 1
fi

# ---------------------------------------------------------------------------
if { ! module_excluded shell && [[ "$(yq_get '.shell.enabled' false "$CONFIG")" == true ]]; } \
   || { ! module_excluded docker && [[ "$(yq_get '.docker.enabled' false "$CONFIG")" == true ]]; }; then
  resolve_target_users || exit 1
  print_kv 'Accounts' "$VM_INIT_TARGET_USERS"
fi
VM_INIT_CONFIG_FINGERPRINT=$(printf '%s' "$VM_INIT_CONFIG_JSON" | { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; } | awk '{print $1}')
print_kv 'Run ID' "$VM_INIT_RUN_ID"
log_info "Using ${VM_INIT_CONFIG_ORIGIN}${VM_INIT_SOURCE_CONFIG:+: $VM_INIT_SOURCE_CONFIG}"

# Preflight: environment facts worth knowing before we start changing things.
# Only the disk check blocks, because it is the one whose failure mode is a
# half-installed machine. Set VM_INIT_MIN_DISK_MB=0 to disable it.
# ---------------------------------------------------------------------------

: "${VM_INIT_MIN_DISK_MB:=2048}"

# Free megabytes on the filesystem backing <path>, or empty if it cannot be read.
_free_mb() {
  df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print int($4 / 1024) }'
}

# True when any enabled module reaches out to the network.
_needs_network() {
  local section
  for section in github_releases github_tools dns docker yazi; do
    [[ "$(yq_get ".${section}.enabled" false "$CONFIG")" == "true" ]] && return 0
  done
  return 1
}

preflight_checks() {
  log_step "Preflight checks"

  local sys_arch
  sys_arch=$(dpkg --print-architecture 2>/dev/null || echo unknown)
  case "$sys_arch" in
    amd64|arm64) log_ok "Architecture: ${sys_arch}" ;;
    *) log_warn "Architecture ${sys_arch} is untested — several modules only ship amd64/arm64 builds" ;;
  esac

  if [[ "${VM_INIT_MIN_DISK_MB}" != "0" ]]; then
    local path free low=""
    for path in / /var /usr/local; do
      [[ -d "$path" ]] || continue
      free=$(_free_mb "$path")
      [[ -n "$free" ]] || continue
      if (( free < VM_INIT_MIN_DISK_MB )); then
        low+="${path} (${free} MB) "
      fi
    done
    if [[ -n "$low" ]]; then
      log_fail "Less than ${VM_INIT_MIN_DISK_MB} MB free on: ${low% }"
      log_info "Free some space, or set VM_INIT_MIN_DISK_MB=0 to skip this check."
      return 1
    fi
    log_ok "Disk space above ${VM_INIT_MIN_DISK_MB} MB on /, /var, /usr/local"
  fi

  # Warn, do not fail: modules retry, and first-boot DNS on a cloud image is
  # routinely slow to settle.
  if _needs_network; then
    if curl -fsS --max-time 8 -o /dev/null https://api.github.com 2>/dev/null; then
      log_ok "github.com reachable"
    else
      log_warn "Cannot reach api.github.com — modules that download releases may fail"
    fi
  fi

  return 0
}

if [[ "$VM_INIT_DRY_RUN" != "1" && "$VM_INIT_VERIFY" != "1" ]]; then
  echo ""
  if ! preflight_checks; then
    exit 1
  fi
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
      list=$(yq -r '.apt.packages // {} | to_entries | .[].value | .[]' "$CONFIG" 2>/dev/null | sort -u | paste -sd' ' -)
      _dry_run_line "Selected APT packages: ${_C_BOLD}${list:-<none>}${_C_RESET}"
      local packages=()
      read -ra packages <<< "$list"
      plan_apt_packages "${packages[@]}"
      ;;
    ufw)
      detect_ssh_connection
      local incoming outgoing rules
      incoming=$(yq -r '.ufw.defaults.incoming // "deny"' "$CONFIG")
      outgoing=$(yq -r '.ufw.defaults.outgoing // "allow"' "$CONFIG")
      rules=$(ufw_effective_rules | sort -u | paste -sd',' -)
      _dry_run_line "Would configure ufw: incoming=${_C_BOLD}${incoming}${_C_RESET}, outgoing=${_C_BOLD}${outgoing}${_C_RESET}, allow=[${_C_BOLD}${rules}${_C_RESET}]"
      if is_installed ufw; then
        local stale
        stale=$(ufw_stale_rule_numbers "$(ufw_effective_rules)" "$(LC_ALL=C ufw status numbered 2>/dev/null || true)")
        [[ -z "$stale" ]] || _dry_run_line "Would remove obsolete vm-init rule numbers: $(paste -sd, - <<< "$stale")"
      fi
      [[ -z "${SSH_CONNECTION:-}" ]] || _dry_run_line "SSH port ${SSH_CONNECTION##* } is preserved; confirm from a new SSH session within ${VM_INIT_FIREWALL_CONFIRM_SECONDS:-120}s"
      ;;
    fail2ban)
      local f2b_bantime f2b_maxretry f2b_banaction f2b_jails
      f2b_bantime=$(yq_get '.fail2ban.bantime' "1h" "$CONFIG")
      f2b_maxretry=$(yq_get '.fail2ban.maxretry' "5" "$CONFIG")
      f2b_banaction=$(yq_get '.fail2ban.banaction' "auto" "$CONFIG")
      f2b_jails=$(yq -r '.fail2ban.jails // {} | to_entries | .[] | select(.value.enabled == true) | .key' "$CONFIG" 2>/dev/null | paste -sd',' -)
      _dry_run_line "Would install ${_C_BOLD}fail2ban${_C_RESET} and enable its service"
      _dry_run_line "Policy:       bantime=${_C_BOLD}${f2b_bantime}${_C_RESET}, maxretry=${_C_BOLD}${f2b_maxretry}${_C_RESET}, banaction=${_C_BOLD}${f2b_banaction}${_C_RESET}"
      _dry_run_line "Active jails: ${_C_BOLD}${f2b_jails:-<none>}${_C_RESET}"
      ;;
    kernel)
      local mitigations_off
      mitigations_off=$(yq_get '.kernel.mitigations_off' false "$CONFIG")
      if [[ "$mitigations_off" == "true" ]]; then
        _dry_run_line "Would add ${_C_BOLD}mitigations=off${_C_RESET} to GRUB_CMDLINE_LINUX_DEFAULT and run update-grub (reboot required)"
      else
        _dry_run_line "Would ensure ${_C_BOLD}mitigations=off${_C_RESET} is absent from GRUB_CMDLINE_LINUX_DEFAULT"
      fi
      ;;
    dns)
      local server port
      server=$(dns_upstream_from_config)
      port=$(yq -r '.dns.listen_port // 5353' "$CONFIG")
      _dry_run_line "Would install dnsproxy and configure systemd-resolved"
      _dry_run_line "Upstream:    ${_C_BOLD}${server}${_C_RESET}"
      _dry_run_line "Listen port: ${_C_BOLD}${port}${_C_RESET}"
      _dry_run_line 'Would update dnsproxy.service, resolved drop-ins, per-link DNS, and /etc/resolv.conf; failed activation restores the saved state'
      ;;
    docker)
      _dry_run_line "Would install ${_C_BOLD}docker-ce${_C_RESET}, docker-ce-cli, containerd.io, buildx, compose plugin"
      local docker_users='' docker_user
      for docker_user in ${VM_INIT_TARGET_USERS:-}; do
        [[ "$docker_user" != root ]] || continue
        docker_users+="${docker_users:+, }${docker_user}"
      done
      if [[ -n "$docker_users" ]]; then
        _dry_run_line "Would add ${docker_users} to the ${_C_BOLD}docker${_C_RESET} group (new login needed)"
      fi
      ;;
    python)
      list=$(yq -r '.python.tools[]? // ""' "$CONFIG" 2>/dev/null | paste -sd',' -)
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
      generic=$(yq -r '.github_releases.generic[]?.binary // ""' "$CONFIG" 2>/dev/null | paste -sd',' -)
      custom=$(yq -r '.github_releases.custom // {} | to_entries | .[] | select(.value == true) | .key' "$CONFIG" 2>/dev/null | paste -sd',' -)
      _dry_run_line "Would install generic binaries: ${_C_BOLD}${generic:-<none>}${_C_RESET}"
      _dry_run_line "Would install custom tools:     ${_C_BOLD}${custom:-<none>}${_C_RESET}"
      ;;
    yazi)
      _dry_run_line "Would add the Yazi apt repository and install ${_C_BOLD}yazi${_C_RESET}"
      ;;
    shell)
      local default_shell aliases
      default_shell=$(yq_get '.shell.default_shell' "fish" "$CONFIG")
      aliases=$(yq -r '.shell.aliases // {} | keys | .[]' "$CONFIG" 2>/dev/null | paste -sd',' -)
      _dry_run_line "Would set default shell: ${_C_BOLD}${default_shell}${_C_RESET} for ${VM_INIT_TARGET_USERS:-<choose account>}"
      _dry_run_line "Required packages: $(shell_required_packages | sort -u | paste -sd, -)"
      local dependencies=() user home_dir
      mapfile -t dependencies < <(shell_required_packages | sort -u)
      plan_apt_packages "${dependencies[@]}"
      _dry_run_line "Would replace only the managed shell file in each selected account; a new session is needed"
      if command -v getent >/dev/null; then
        while IFS=: read -r user home_dir; do
          _dry_run_line "${user}: $(shell_managed_path "$default_shell" "$home_dir")"
        done < <(target_users)
      fi
      _dry_run_line "Would configure aliases: ${_C_BOLD}${aliases:-<none>}${_C_RESET}"
      ;;
    *)
      _dry_run_line "${_C_DIM}(no preview available for ${section})${_C_RESET}"
      ;;
  esac
  val=$(yq_get ".${section}.enabled" false "$CONFIG")
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
declare -a VM_INIT_MODULE_ELAPSED=()

# run_module and verify_module report through this global rather than their exit
# status. Bash suppresses errexit inside *every* command reached through an
# if/&&/|| condition, so calling them as `run_module ... || rc=$?` would silently
# disable the `set -e` that run_with_errexit depends on to stop a module at its
# first failing step -- see the warning on run_with_errexit in _common.sh.
VM_INIT_LAST_MODULE_RC=0

record_module_status() {
  VM_INIT_MODULE_NAMES+=("$1")
  VM_INIT_MODULE_STATUS+=("$2")
  VM_INIT_MODULE_DETAIL+=("$3")
  VM_INIT_MODULE_ELAPSED+=("${4:-}")
}

# A successful command can still leave an explicit action, or report warnings.
# Notes alone never change readiness. Failed commands always take precedence.
record_module_result() {
  local section="$1" rc="$2" warnings="$3" elapsed="$4" success_detail="${5:-}" failure_detail="${6:-exit $2}"
  local action_detail captured_warnings
  action_detail=$(vm_init_notes | awk -F '\t' -v module="$section" \
    '$1 == "action" && $2 == module && !found { print ($3 == "-" ? "see required actions" : $3); found=1 }')
  captured_warnings=$(vm_init_notes | awk -F '\t' -v module="$section" \
    '$1 == "warning" && $2 == module { n++ } END { print n+0 }')
  if (( captured_warnings > warnings )); then warnings="$captured_warnings"; fi
  if (( rc != 0 )); then
    record_module_status "$section" failed "$failure_detail" "$elapsed"
  elif [[ -n "$action_detail" ]]; then
    if (( warnings > 0 )); then action_detail+="; ${warnings} warning(s)"; fi
    record_module_status "$section" needs_action "$action_detail" "$elapsed"
  elif (( warnings > 0 )); then
    record_module_status "$section" warned "${warnings} warning(s); see below" "$elapsed"
  else
    record_module_status "$section" ok "$success_detail" "$elapsed"
  fi
}

# Load a module's functions unless they are already defined. Single-file bundles
# pre-define every module, so this guard is what lets one orchestrator serve both
# layouts. Keyed on the install entry point, which every module defines.
source_module() {
  local module_file="$1" entry_func="$2"
  declare -F "$entry_func" >/dev/null 2>&1 && return 0
  # shellcheck source=/dev/null
  source "${MODULES_DIR}/${module_file}"
}

# Shared prologue for run_module and verify_module: prints the section header and
# decides whether this module runs at all.
# Returns 0 to proceed, 1 when the module was skipped and recorded.
_module_should_run() {
  local section="$1" progress="$2"
  local enabled

  if module_excluded "$section"; then
    if [[ "$VM_INIT_VERBOSE" == 1 ]]; then log_skip "${section}: excluded by --only/--skip"; fi
    record_module_status "$section" "skipped" "excluded by filter"
    return 1
  fi

  enabled=$(yq_get ".${section}.enabled" false "$CONFIG")
  if [[ "$enabled" != "true" ]]; then
    if [[ "$VM_INIT_VERBOSE" == 1 ]]; then log_skip "${section}: disabled in config"; fi
    record_module_status "$section" "skipped" "disabled in config"
    return 1
  fi

  log_section "${section}" "${progress}"
  return 0
}

run_module() {
  local section="$1" module_file="$2" entry_func="$3" progress="${4:-}"
  local rc=0 pre_warn new_warns start_ts elapsed status
  local VM_INIT_CURRENT_MODULE="$section"

  VM_INIT_LAST_MODULE_RC=0
  _module_should_run "$section" "$progress" || return 0

  if [[ "$VM_INIT_DRY_RUN" == "1" ]]; then
    source_module "$module_file" "$entry_func"
    dry_run_preview "$section"
    record_module_status "$section" "ok" "planned; no changes"
    return 0
  fi

  pre_warn="${VM_INIT_WARN_COUNT:-0}"
  start_ts=$(date +%s)

  source_module "$module_file" "$entry_func"

  set +e
  run_with_errexit "$entry_func"
  rc=$?
  set -e

  elapsed=$(( $(date +%s) - start_ts ))
  new_warns=$(( ${VM_INIT_WARN_COUNT:-0} - pre_warn ))

  record_module_result "$section" "$rc" "$new_warns" "$elapsed"
  status="${VM_INIT_MODULE_STATUS[${#VM_INIT_MODULE_STATUS[@]}-1]}"

  # Remember the outcome so a later --verify can tell "never provisioned here"
  # apart from "provisioned once, then drifted".
  state_set "module.${section}.status" "$status" 2>/dev/null || true
  state_set "module.${section}.ts" "$(date +%Y-%m-%dT%H:%M:%S)" 2>/dev/null || true

  VM_INIT_LAST_MODULE_RC="$rc"
  return 0
}

# Read-only counterpart to run_module: calls the module's verify_<section>
# function, if it defines one, and records the result in the same vocabulary.
verify_module() {
  local section="$1" module_file="$2" entry_func="$3" progress="${4:-}"
  local rc=0 pre_warn new_warns start_ts elapsed verify_func last_status last_ts
  local VM_INIT_CURRENT_MODULE="$section"

  VM_INIT_LAST_MODULE_RC=0
  _module_should_run "$section" "$progress" || return 0

  last_status=$(state_get "module.${section}.status" 2>/dev/null || true)
  last_ts=$(state_get "module.${section}.ts" 2>/dev/null || true)
  if [[ -n "$last_status" ]]; then
    log_info "last run: ${last_status}${last_ts:+ (${last_ts})}"
  else
    log_info "last run: no record on this machine"
  fi

  source_module "$module_file" "$entry_func"

  verify_func="verify_${section}"
  if ! declare -F "$verify_func" >/dev/null 2>&1; then
    log_skip "no verification available for ${section}"
    record_module_status "$section" "skipped" "no verify function"
    return 0
  fi

  pre_warn="${VM_INIT_WARN_COUNT:-0}"
  start_ts=$(date +%s)

  set +e
  run_with_errexit "$verify_func"
  rc=$?
  set -e

  elapsed=$(( $(date +%s) - start_ts ))
  new_warns=$(( ${VM_INIT_WARN_COUNT:-0} - pre_warn ))

  record_module_result "$section" "$rc" "$new_warns" "$elapsed" verified 'verification failed'

  VM_INIT_LAST_MODULE_RC="$rc"
  return 0
}

if [[ "$VM_INIT_SETUP" == 1 && "$VM_INIT_DRY_RUN" != 1 ]]; then
  setup_rc=0
  confirm_setup_plan || setup_rc=$?
  if [[ "$setup_rc" == 2 ]]; then exit 0; elif [[ "$setup_rc" != 0 ]]; then exit 1; fi
fi
if [[ "$VM_INIT_DRY_RUN" != 1 && "$VM_INIT_VERIFY" != 1 ]]; then
  save_run_context || exit 1
  CONFIG="$VM_INIT_RETRY_CONFIG"
  state_set last.force "$VM_INIT_FORCE"
  state_set last.no_upgrade "$VM_INIT_NO_UPGRADE"
  state_set last.failed ''
fi

VM_INIT_TOTAL_MODULES=0
VM_INIT_PENDING_MODULES=''
for spec in "${VM_INIT_MODULES[@]}"; do
  section="${spec%%:*}"
  if ! module_excluded "$section" && [[ "$(yq_get ".${section}.enabled" false "$CONFIG")" == true ]]; then
    VM_INIT_TOTAL_MODULES=$((VM_INIT_TOTAL_MODULES + 1))
    VM_INIT_PENDING_MODULES+="${VM_INIT_PENDING_MODULES:+,}${section}"
  fi
done
if [[ "$VM_INIT_DRY_RUN" != 1 && "$VM_INIT_VERIFY" != 1 ]]; then
  state_set last.failed "$VM_INIT_PENDING_MODULES"
fi
if [[ "$VM_INIT_TOTAL_MODULES" == 0 ]]; then log_info 'No modules selected; nothing to apply or verify.'; fi
VM_INIT_MODULE_INDEX=0
VM_INIT_ABORTED=0
for module_spec in "${VM_INIT_MODULES[@]}"; do
  IFS=':' read -r section module_file entry_func <<< "$module_spec"
  if ! module_excluded "$section" && [[ "$(yq_get ".${section}.enabled" false "$CONFIG")" == true ]]; then
    VM_INIT_MODULE_INDEX=$((VM_INIT_MODULE_INDEX + 1))
  fi

  if (( VM_INIT_ABORTED )); then
    if ! module_excluded "$section" && [[ "$(yq_get ".${section}.enabled" false "$CONFIG")" == true ]]; then
      record_module_status "$section" "not_run" 'stopped after earlier failure'
    else
      record_module_status "$section" "skipped" 'not selected'
    fi
    continue
  fi

  # Called bare, never through `||` or an `if` test -- see VM_INIT_LAST_MODULE_RC.
  if [[ "$VM_INIT_VERIFY" == "1" ]]; then
    verify_module "$section" "$module_file" "$entry_func" \
      "${VM_INIT_MODULE_INDEX}/${VM_INIT_TOTAL_MODULES}"
  else
    run_module "$section" "$module_file" "$entry_func" \
      "${VM_INIT_MODULE_INDEX}/${VM_INIT_TOTAL_MODULES}"
  fi

  if [[ "$VM_INIT_DRY_RUN" != 1 && "$VM_INIT_VERIFY" != 1 && "$VM_INIT_LAST_MODULE_RC" == 0 ]]; then
    VM_INIT_PENDING_MODULES=",${VM_INIT_PENDING_MODULES},"
    VM_INIT_PENDING_MODULES="${VM_INIT_PENDING_MODULES/,$section,/,}"
    VM_INIT_PENDING_MODULES="${VM_INIT_PENDING_MODULES#,}"
    VM_INIT_PENDING_MODULES="${VM_INIT_PENDING_MODULES%,}"
    state_set last.failed "$VM_INIT_PENDING_MODULES"
  fi

  if (( VM_INIT_LAST_MODULE_RC != 0 )) && [[ "$VM_INIT_FAIL_FAST" == "1" ]]; then
    VM_INIT_ABORTED=1
    log_fail "Stopping after ${section} (--fail-fast)"
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

# Firewall confirmation/rollback can finish while later modules are running.
reconcile_firewall_result() {
  local i firewall_run firewall_result
  if [[ "$VM_INIT_DRY_RUN" != 1 && "$VM_INIT_VERIFY" != 1 && -f "$VM_INIT_STATE_DIR/firewall-result" ]]; then
    read -r firewall_run firewall_result < "$VM_INIT_STATE_DIR/firewall-result"
    if [[ "$firewall_run" == "$VM_INIT_RUN_ID" ]]; then
      for ((i=0; i<${#VM_INIT_MODULE_NAMES[@]}; i++)); do
        [[ "${VM_INIT_MODULE_NAMES[$i]}" == ufw && "${VM_INIT_MODULE_STATUS[$i]}" != failed ]] || continue
        case "$firewall_result" in
          rolled_back) VM_INIT_MODULE_STATUS[i]=failed; VM_INIT_MODULE_DETAIL[i]='confirmation expired; previous firewall restored' ;;
          confirmed)
            VM_INIT_MODULE_STATUS[i]=ok
            VM_INIT_MODULE_DETAIL[i]='confirmed from a new session'
            if vm_init_notes | awk -F '\t' '$1 == "warning" && $2 == "ufw" { found=1 } END { exit !found }'; then
              VM_INIT_MODULE_STATUS[i]=warned
              VM_INIT_MODULE_DETAIL[i]+='; see warnings below'
            fi
            ;;
        esac
        state_set module.ufw.status "${VM_INIT_MODULE_STATUS[$i]}"
      done
    fi
  fi
}

# Keep status, module and duration aligned even when a detail is long.
_summary_row() {
  local color="$1" sym="$2" name="$3" detail="$4" secs="$5"
  local suffix="" dur=""
  [[ -n "$detail" ]] && suffix="(${detail})"
  [[ -n "$secs" ]] && dur="$(format_duration "$secs")"
  printf "  ${color}%-13s${_C_RESET} %-18s ${_C_DIM}%6s%s${_C_RESET}\n" \
    "$sym" "$name" "$dur" "${suffix:+  $suffix}"
}

print_message_group() {
  local kind="$1" title="$2" category module summary message count=0 marker
  while IFS=$'\t' read -r category module summary message; do
    [[ "$category" == "$kind" ]] || continue
    if (( count == 0 )); then
      echo ""
      echo -e "${_C_BOLD}${title}${_C_RESET}"
    fi
    count=$((count + 1))
    marker="${_SYM_BULLET}"
    if [[ "$kind" == action ]]; then marker="${count}."; fi
    printf "  ${_C_CYAN}%s${_C_RESET} %s: %s\n" "$marker" "$module" "$message"
  done < <(vm_init_notes)
}

print_next_steps() {
  print_message_group action 'Required actions'
  print_message_group warning 'Warnings'
  print_message_group session 'Session changes'
  print_message_group info 'Notes'
}

print_summary() {
  local i name status detail secs
  local ok=0 skip=0 warn=0 fail=0 action=0 not_run=0
  local total=${#VM_INIT_MODULE_NAMES[@]}
  local failed_names=""
  local end_ts elapsed title ready_label=ready completion=Setup
  end_ts=$(date +%s)
  elapsed=$(( end_ts - VM_INIT_START_TS ))

  if [[ "$VM_INIT_VERIFY" == "1" ]]; then
    title="Verification"
    completion="Verification"
  else
    title="Summary"
  fi

  echo ""
  echo -e "${_C_BOLD}${_C_MAGENTA}━━━ ${title} ━━━${_C_RESET}"
  for ((i = 0; i < total; i++)); do
    name="${VM_INIT_MODULE_NAMES[$i]}"
    status="${VM_INIT_MODULE_STATUS[$i]}"
    detail="${VM_INIT_MODULE_DETAIL[$i]}"
    secs="${VM_INIT_MODULE_ELAPSED[$i]:-}"
    case "$status" in
      ok)
        ok=$((ok + 1))
        if [[ "$VM_INIT_DRY_RUN" == 1 ]]; then
          _summary_row "${_C_CYAN}" 'Planned' "$name" "$detail" "$secs"
        else
          _summary_row "${_C_GREEN}" 'Ready' "$name" "$detail" "$secs"
        fi
        ;;
      skipped)
        skip=$((skip + 1))
        if [[ "$VM_INIT_VERBOSE" == 1 ]]; then _summary_row "${_C_DIM}" "${_SYM_SKIP}" "$name" "$detail" "$secs"; fi
        ;;
      needs_action)
        action=$((action + 1))
        _summary_row "${_C_YELLOW}" "Needs action" "$name" "$detail" "$secs"
        ;;
      warned)
        warn=$((warn + 1))
        _summary_row "${_C_YELLOW}" "Warnings" "$name" "$detail" "$secs"
        ;;
      not_run)
        not_run=$((not_run + 1))
        failed_names+="${name},"
        _summary_row "${_C_DIM}" "Not run" "$name" "$detail" "$secs"
        ;;
      failed)
        fail=$((fail + 1))
        failed_names+="${name},"
        _summary_row "${_C_RED}" "Failed" "$name" "$detail" "$secs"
        ;;
    esac
  done

  if (( skip > 0 )); then printf '  Not selected: %d modules (use --list-modules for details)\n' "$skip"; fi
  echo ""
  print_rule 60
  if [[ "$VM_INIT_DRY_RUN" == 1 ]]; then ready_label=planned; fi
  printf "  ${_C_GREEN}%s${_C_RESET}: %d   ${_C_YELLOW}needs action${_C_RESET}: %d   ${_C_YELLOW}warned${_C_RESET}: %d   ${_C_RED}failed${_C_RESET}: %d\n" \
    "$ready_label" "$ok" "$action" "$warn" "$fail"
  printf "  ${_C_DIM}skipped: %d" "$skip"
  if (( not_run > 0 )); then printf '   not run: %d' "$not_run"; fi
  printf "   elapsed: %s${_C_RESET}\n" "$(format_duration "$elapsed")"

  if [[ -n "${VM_INIT_TALLY_FILE:-}" && -f "${VM_INIT_TALLY_FILE}" ]]; then
    local installed_tools=0 upgraded_tools=0 current_tools=0
    installed_tools=$(grep -c '^installed$' "$VM_INIT_TALLY_FILE" 2>/dev/null) || installed_tools=0
    upgraded_tools=$(grep -c '^upgraded$' "$VM_INIT_TALLY_FILE" 2>/dev/null) || upgraded_tools=0
    current_tools=$(grep -c '^current$' "$VM_INIT_TALLY_FILE" 2>/dev/null) || current_tools=0
    if (( installed_tools + upgraded_tools + current_tools > 0 )); then
      printf "  ${_C_BRIGHT_GREEN}installed${_C_RESET}: %d   ${_C_BRIGHT_CYAN}upgraded${_C_RESET}: %d   ${_C_GREEN}current${_C_RESET}: %d\n" \
        "$installed_tools" "$upgraded_tools" "$current_tools"
    fi
  fi

  [[ -n "${LOG_FILE:-}" ]] && printf "  ${_C_DIM}Log:${_C_RESET} ${_C_CYAN}%s${_C_RESET}\n" "${LOG_FILE}"

  # Print notes before the pass/fail verdict: a pending reboot does not stop
  # mattering because some other module had a bad day.
  print_next_steps

  if [[ "$VM_INIT_DRY_RUN" != 1 && "$VM_INIT_VERIFY" != 1 ]]; then state_set last.failed "${failed_names%,}"; fi
  if (( fail > 0 || not_run > 0 )); then
    echo ""
    if [[ "$VM_INIT_VERIFY" == "1" ]]; then
      echo -e "  ${_C_RED}${_C_BOLD}${_SYM_FAIL} Some modules did not verify.${_C_RESET}"
      echo -e "  ${_C_DIM}Re-provision just those:${_C_RESET}  ${_C_CYAN}$(retry_command apply "${failed_names%,}")${_C_RESET}"
    else
      echo -e "  ${_C_RED}${_C_BOLD}${_SYM_FAIL} Some modules failed.${_C_RESET} Review output above or in the log file."
      # Name the exact re-run rather than leaving the reader to reconstruct it.
      echo -e "  ${_C_DIM}Retry failed and unfinished modules:${_C_RESET}  ${_C_CYAN}$(retry_command apply "${failed_names%,}")${_C_RESET}"
      echo -e "  ${_C_DIM}Check current state:${_C_RESET}      ${_C_CYAN}$(retry_command status)${_C_RESET}"
    fi
    return 1
  fi

  if [[ "$VM_INIT_DRY_RUN" == "1" ]]; then
    echo ""
    echo -e "  ${_C_YELLOW}${_SYM_INFO} Dry run complete${_C_RESET} — no changes made."
    return 0
  fi

  echo ""
  if (( action > 0 )); then
    local module_word=modules
    if (( action == 1 )); then module_word=module; fi
    echo -e "  ${_C_YELLOW}${_SYM_WARN} ${completion} finished; action required for ${action} ${module_word}.${_C_RESET} See Required actions above."
  elif (( warn > 0 )) || [[ -n "$(vm_init_notes | awk -F '\t' '$1 == "warning"')" ]]; then
    echo -e "  ${_C_YELLOW}${_SYM_WARN} ${completion} completed with warnings.${_C_RESET} See Warnings above."
  else
    log_done "${completion} complete."
  fi
  if [[ "$VM_INIT_VERIFY" != 1 || "$action" != 0 ]]; then
    local verify_label='Verify at any time with'
    if (( action > 0 )); then verify_label='After completing the actions, verify with'; fi
    echo -e "  ${verify_label}: ${_C_CYAN}${_C_BOLD}$(retry_command status)${_C_RESET}"
  fi
  return 0
}

reconcile_firewall_result
if [[ "$VM_INIT_JSON" == 1 ]]; then
  print_json_summary
else
  print_summary
fi
