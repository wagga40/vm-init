#!/usr/bin/env bash
# Shared helpers for vm-init modules. Sourced by vm-init.sh before any module.

# ---------- Colors, symbols & terminal detection ----------
#
# Color is enabled when stdout is a TTY and the terminal reports color
# support. Honors the NO_COLOR standard (https://no-color.org) and the
# VM_INIT_NO_COLOR escape hatch. Force-enable with VM_INIT_FORCE_COLOR=1
# (useful in CI logs where --verbose output is still nicer with colors).
# Unicode status symbols are used when the locale advertises UTF-8.

_vm_init_detect_ui() {
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
    _C_RESET="\033[0m"
    _C_BOLD="\033[1m"
    _C_DIM="\033[2m"
    _C_UNDER="\033[4m"
    _C_GREEN="\033[32m"
    _C_CYAN="\033[36m"
    _C_YELLOW="\033[33m"
    _C_RED="\033[31m"
    _C_MAGENTA="\033[35m"
    _C_BLUE="\033[34m"
    _C_BRIGHT_GREEN="\033[92m"
    _C_BRIGHT_CYAN="\033[96m"
    _C_BRIGHT_YELLOW="\033[93m"
    _C_BRIGHT_RED="\033[91m"
  else
    _C_RESET="" _C_BOLD="" _C_DIM="" _C_UNDER=""
    _C_GREEN="" _C_CYAN="" _C_YELLOW="" _C_RED=""
    _C_MAGENTA="" _C_BLUE=""
    _C_BRIGHT_GREEN="" _C_BRIGHT_CYAN=""
    _C_BRIGHT_YELLOW="" _C_BRIGHT_RED=""
  fi

  if (( use_color && use_unicode )); then
    _SYM_ARROW="▶"
    _SYM_OK="✔"
    _SYM_SKIP="○"
    _SYM_WARN="▲"
    _SYM_FAIL="✘"
    _SYM_INFO="ℹ"
    _SYM_BULLET="•"
    _SYM_RULE="─"
  else
    _SYM_ARROW="==>"
    _SYM_OK="[OK]"
    _SYM_SKIP="[--]"
    _SYM_WARN="[!!]"
    _SYM_FAIL="[XX]"
    _SYM_INFO="[ii]"
    _SYM_BULLET="-"
    _SYM_RULE="-"
  fi

  _VM_INIT_USE_COLOR="$use_color"
  _VM_INIT_USE_UNICODE="$use_unicode"
  export _VM_INIT_USE_COLOR _VM_INIT_USE_UNICODE
}

_vm_init_detect_ui

: "${VM_INIT_WARN_COUNT:=0}"
: "${VM_INIT_CMD_TIMEOUT:=900}"
export VM_INIT_WARN_COUNT
export VM_INIT_CMD_TIMEOUT

# ---------- Logging ----------

log_step()  { echo -e "${_C_CYAN}${_C_BOLD}${_SYM_ARROW}${_C_RESET} ${_C_BOLD}$1${_C_RESET}"; }
log_ok()    { echo -e "  ${_C_GREEN}${_SYM_OK}${_C_RESET} $1"; }
log_skip()  { echo -e "  ${_C_DIM}${_SYM_SKIP} $1${_C_RESET}"; }
log_warn()  {
  VM_INIT_WARN_COUNT=$((VM_INIT_WARN_COUNT + 1))
  echo -e "  ${_C_YELLOW}${_SYM_WARN}${_C_RESET} $1"
}
log_fail()  { echo -e "  ${_C_RED}${_SYM_FAIL}${_C_RESET} $1" >&2; }
log_info()  { echo -e "  ${_C_BLUE}${_SYM_INFO}${_C_RESET} $1"; }
log_done()  { echo -e "${_C_BRIGHT_GREEN}${_C_BOLD}${_SYM_OK}${_C_RESET} ${_C_BOLD}$1${_C_RESET}"; }

# Module section header with an optional progress fragment rendered dim.
#   log_section "apt"            → ━━━ apt ━━━
#   log_section "apt" "1/9"      → ━━━ apt  1/9 ━━━
log_section() {
  local title="$1" progress="${2:-}"
  echo ""
  if [[ -n "$progress" ]]; then
    echo -e "${_C_MAGENTA}${_C_BOLD}━━━ ${title}${_C_RESET}  ${_C_DIM}${progress}${_C_RESET}  ${_C_MAGENTA}${_C_BOLD}━━━${_C_RESET}"
  else
    echo -e "${_C_MAGENTA}${_C_BOLD}━━━ ${title} ━━━${_C_RESET}"
  fi
}

# ---------- UI formatting helpers ----------

# Print a horizontal rule of WIDTH characters using the configured rule glyph.
#   print_rule           → 60 chars
#   print_rule 40        → 40 chars
print_rule() {
  local width="${1:-60}" i out=""
  for ((i = 0; i < width; i++)); do out+="${_SYM_RULE}"; done
  echo -e "${_C_DIM}${out}${_C_RESET}"
}

# Print a left-aligned label followed by a value. Label is dim, value plain.
#   print_kv "Config" "/etc/vm-init/vm-init.yml"
# Optional third arg overrides label column width (default: 14).
print_kv() {
  local label="$1" value="${2:-}" width="${3:-14}"
  printf "  ${_C_DIM}%-${width}s${_C_RESET} %b\n" "${label}" "${value}"
}

# Print a small, consistent help-text section header. Used by all CLI
# entry points (vm-init.sh, scripts/install.sh, recover-dns.sh) so their help
# output shares a common visual language.
#   print_help_section "Options"
print_help_section() {
  echo ""
  echo -e "${_C_BOLD}${_C_MAGENTA}$1${_C_RESET}"
}

# Print a short status legend mapping symbol → status → meaning. Used in
# --help output and anywhere a reader might wonder what [OK] etc. mean.
# Pads the symbol to 4 columns so ASCII "==>" and "[OK]" align in both modes.
print_status_legend() {
  printf "  ${_C_GREEN}%-4s${_C_RESET} %-6s %s\n"  "${_SYM_OK}"    "ok"    "step completed"
  printf "  ${_C_DIM}%-4s %-6s %s${_C_RESET}\n"    "${_SYM_SKIP}"  "skip"  "skipped (filter or disabled in config)"
  printf "  ${_C_YELLOW}%-4s${_C_RESET} %-6s %s\n" "${_SYM_WARN}"  "warn"  "completed with warnings"
  printf "  ${_C_RED}%-4s${_C_RESET} %-6s %s\n"    "${_SYM_FAIL}"  "fail"  "module failed"
  printf "  ${_C_BLUE}%-4s${_C_RESET} %-6s %s\n"   "${_SYM_INFO}"  "info"  "informational message"
  printf "  ${_C_CYAN}%-4s${_C_RESET} %-6s %s\n"   "${_SYM_ARROW}" "step"  "starting a step"
}

# Format a duration given in whole seconds as "Xm Ys" or "Xh Ym Zs".
#   format_duration 75     → "1m 15s"
format_duration() {
  local total="${1:-0}"
  local h=$((total / 3600))
  local m=$(( (total % 3600) / 60 ))
  local s=$((total % 60))
  if (( h > 0 )); then
    printf "%dh %dm %ds" "$h" "$m" "$s"
  elif (( m > 0 )); then
    printf "%dm %ds" "$m" "$s"
  else
    printf "%ds" "$s"
  fi
}

# ---------- Quiet runner ----------
# Runs a command silently unless VM_INIT_VERBOSE=1.
# On failure the captured output is printed regardless.
_timeout_bin() {
  command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null
}

run_maybe_timeout() {
  local cmd="$1"
  local timeout_bin=""

  if [[ "${VM_INIT_CMD_TIMEOUT:-0}" != "0" ]] \
      && ! declare -F "$cmd" >/dev/null 2>&1; then
    timeout_bin=$(_timeout_bin || true)
  fi

  if [[ -n "$timeout_bin" ]]; then
    "$timeout_bin" --preserve-status "$VM_INIT_CMD_TIMEOUT" "$@"
  else
    "$@"
  fi
}

run_quiet() {
  if [[ "${VM_INIT_VERBOSE:-0}" == "1" ]]; then
    run_maybe_timeout "$@"
  else
    local _out _rc=0
    _out=$(run_maybe_timeout "$@" 2>&1) || _rc=$?
    if [[ $_rc -ne 0 ]]; then
      log_fail "Command failed (exit ${_rc}): $*"
      echo "$_out" >&2
      return "$_rc"
    fi
  fi
}

# Run a module entry point with errexit active inside the wrapped function while
# still letting the orchestrator capture its exit code and print a summary.
#
# Callers that need to inspect the return code should disable errexit before
# invoking this helper; do not put the helper itself in an if/||/&& condition,
# because Bash disables errexit inside commands reached through those contexts.
run_with_errexit() {
  local _errexit_was_set=0 _rc=0 _warn_file _warn_count
  case "$-" in
    *e*) _errexit_was_set=1 ;;
  esac

  _warn_file=$(mktemp) || return 1

  set +e
  (
    set -e
    trap 'printf "%s\n" "${VM_INIT_WARN_COUNT:-0}" > "$_warn_file"' EXIT
    "$@"
  )
  _rc=$?

  if [[ -s "$_warn_file" ]]; then
    _warn_count=$(<"$_warn_file")
    if [[ "$_warn_count" =~ ^[0-9]+$ ]]; then
      VM_INIT_WARN_COUNT="$_warn_count"
      export VM_INIT_WARN_COUNT
    fi
  fi
  rm -f "$_warn_file"

  if (( _errexit_was_set )); then
    set -e
  else
    set +e
  fi
  return "$_rc"
}

is_installed() {
  command -v "$1" >/dev/null 2>&1
}

require_commands() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if (( ${#missing[@]} > 0 )); then
    log_fail "Missing required command(s): ${missing[*]}"
    log_info "Install them first, or run the apt module before this module."
    return 1
  fi
}

should_force() {
  [[ "${VM_INIT_FORCE:-0}" == "1" ]]
}

# Read a YAML value, substituting a default only when the key is absent (null).
# Unlike `yq '.x // default'` which also treats `false` as missing, this helper
# only falls back when yq returns the literal string "null".
#
# Usage: val=$(yq_get '.path.to.key' 'default' "$CONFIG")
yq_get() {
  local path="$1" default="$2" config="$3"
  local val
  val=$(yq -r "$path" "$config")
  if [[ "$val" == "null" ]]; then
    echo "$default"
  else
    echo "$val"
  fi
}

# Print "username:home_dir" lines for human users on the system (UID 1000-60000,
# shell is not nologin/false). More robust than iterating over /home/*.
# Callers can parse with: `while IFS=: read -r user home; do ...; done < <(human_users)`
human_users() {
  getent passwd \
    | awk -F: -v min="${VM_INIT_UID_MIN:-1000}" -v max="${VM_INIT_UID_MAX:-60000}" '
        $3 >= min && $3 <= max && $7 !~ /(nologin|false)$/ { print $1 ":" $6 }
      '
}

# ---------- Retry + network helpers ----------

# Run a command with retries + exponential backoff.
# Env: VM_INIT_RETRIES (default 3), VM_INIT_RETRY_DELAY (default 2s)
with_retries() {
  local max="${VM_INIT_RETRIES:-3}"
  local delay="${VM_INIT_RETRY_DELAY:-2}"
  local attempt rc=0
  for (( attempt = 1; attempt <= max; attempt++ )); do
    rc=0
    "$@" && return 0 || rc=$?
    if (( attempt < max )); then
      sleep "$delay"
      delay=$((delay * 2))
    fi
  done
  return "$rc"
}

# Plain curl with transient-error retries at the HTTP layer (handles 5xx/408/429)
# and with_retries wrapping for hard network failures. Fails on any HTTP error.
curl_retry() {
  with_retries curl -fsSL \
    --retry 3 --retry-delay 2 --retry-connrefused \
    --connect-timeout 15 --max-time 300 \
    "$@"
}

download_file() {
  local url="$1" dest="$2"
  shift 2
  curl_retry "$@" -o "$dest" "$url"
}

# Build the curl auth arguments for GitHub API if GH_TOKEN/GITHUB_TOKEN are set.
_github_auth_args() {
  if [[ -n "${GH_TOKEN:-}" ]]; then
    printf '%s\n' "-H" "Authorization: Bearer ${GH_TOKEN}"
  elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    printf '%s\n' "-H" "Authorization: Bearer ${GITHUB_TOKEN}"
  fi
}

# ---------- Checksum verification ----------

# Compute sha256 of a file. Prints hash to stdout.
# Works with GNU sha256sum or BSD shasum.
_sha256_of() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    return 127
  fi
}

# Verify a file's sha256.
#
# Usage:
#   verify_sha256 <file> <expected-hash>
#   verify_sha256 <file> --from <sha256_url>
#
# Exit codes:
#   0 = verified
#   1 = mismatch
#   2 = sha256 sidecar not available (url returned non-200)
#   3 = no sha256 tool installed
verify_sha256() {
  local file="$1"
  local expected="$2"
  local sha_url=""

  if [[ "$expected" == "--from" ]]; then
    sha_url="$3"
    local sha_tmp
    sha_tmp=$(mktemp)
    if ! curl_retry -o "$sha_tmp" "$sha_url" 2>/dev/null; then
      rm -f "$sha_tmp"
      return 2
    fi
    # Extract hash from "HASH  filename" format, or plain hash line, or
    # "HASH *filename" (BSD format).
    expected=$(awk 'NF>=1 {print $1; exit}' "$sha_tmp")
    rm -f "$sha_tmp"
    if [[ -z "$expected" ]]; then
      return 2
    fi
  fi

  local actual
  if ! actual=$(_sha256_of "$file"); then
    return 3
  fi

  if [[ "$actual" != "$expected" ]]; then
    log_fail "Checksum mismatch for $(basename "$file")"
    log_fail "  expected: $expected"
    log_fail "  actual:   $actual"
    return 1
  fi
  return 0
}

# Best-effort verification against a GitHub release's .sha256 sidecar. Logs OK
# on success, warns and returns 0 if no sidecar exists (so callers don't abort
# on projects that don't publish .sha256 files).
try_verify_github_asset() {
  local file="$1" sha_url="$2"
  if verify_sha256 "$file" --from "$sha_url"; then
    log_info "sha256 verified ($(basename "$file"))"
    return 0
  fi
  local rc=$?
  case "$rc" in
    2) log_warn "No .sha256 sidecar at ${sha_url} — checksum skipped" ;;
    3) log_warn "No sha256 tool available — checksum skipped" ;;
    *) return "$rc" ;;
  esac
  return 0
}

# ---------- GitHub helpers ----------

# Cache latest-version lookups for the duration of a run so each module doesn't
# re-hit the GitHub API rate limit.
declare -A _VM_INIT_VERSION_CACHE=()

# Fetch the latest release tag for <owner>/<repo>.
# Honors GH_TOKEN / GITHUB_TOKEN for authenticated requests (5000/hr vs 60/hr).
github_latest_version() {
  local repo="$1"
  require_commands jq || return 1
  if [[ -n "${_VM_INIT_VERSION_CACHE[$repo]:-}" ]]; then
    echo "${_VM_INIT_VERSION_CACHE[$repo]}"
    return 0
  fi
  local auth_args=() tag
  mapfile -t auth_args < <(_github_auth_args)
  if ! tag=$(curl_retry \
        "${auth_args[@]}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${repo}/releases/latest" \
      | jq -r .tag_name); then
    log_fail "GitHub API request failed for ${repo}"
    return 1
  fi
  if [[ -z "$tag" || "$tag" == "null" ]]; then
    log_fail "No latest release found for ${repo}"
    return 1
  fi
  _VM_INIT_VERSION_CACHE[$repo]="$tag"
  echo "$tag"
}

# ---------- GitHub release binary installer ----------

# Download a binary from a GitHub release tarball, verify its sha256 sidecar
# when available, and install to /usr/local/bin.
#
# Usage: download_github_release <repo> <asset_pattern> <binary> <arch_value>
#
# <asset_pattern> may contain:
#   {version}     — release tag with leading "v" stripped
#   {arch}        — replaced with <arch_value>
#   {arch_suffix} — replaced with <arch_value> (alias, same substitution)
download_github_release() {
  local repo="$1" pattern="$2" binary="$3" arch_value="$4"

  if is_installed "$binary" && ! should_force; then
    log_skip "${binary} already installed"
    return 0
  fi

  log_step "Installing ${binary} from ${repo}"

  local tag version asset url sha_url
  if ! tag=$(github_latest_version "$repo"); then
    return 1
  fi
  version="${tag#v}"

  asset="$pattern"
  asset="${asset//\{version\}/$version}"
  asset="${asset//\{arch\}/$arch_value}"
  asset="${asset//\{arch_suffix\}/$arch_value}"
  url="https://github.com/${repo}/releases/download/${tag}/${asset}"
  sha_url="${url}.sha256"

  local tmp
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064  # $tmp must expand now so cleanup knows the path
  trap "rm -rf -- '${tmp}'" RETURN

  if ! download_file "$url" "$tmp/$asset"; then
    log_fail "Failed to download ${url}"
    return 1
  fi

  if ! try_verify_github_asset "$tmp/$asset" "$sha_url"; then
    log_fail "Checksum failed for ${asset}"
    return 1
  fi

  if ! run_quiet tar xzf "$tmp/$asset" -C /usr/local/bin "$binary"; then
    log_fail "Failed to extract ${binary} from ${asset}"
    return 1
  fi
  chmod +x "/usr/local/bin/${binary}"
  log_ok "${binary} installed"
}
