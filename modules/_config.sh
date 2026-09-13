#!/usr/bin/env bash
# Configuration and account handling shared by interactive and automated runs.

bootstrap_config_tools() {
  local command missing=() needs_yq=0
  for command in jq python3; do
    if ! command -v "$command" >/dev/null; then missing+=("$command"); fi
  done
  if ! command -v yq >/dev/null; then
    needs_yq=1
    missing+=(curl ca-certificates)
  fi
  if (( ${#missing[@]} > 0 || needs_yq )); then
    if [[ $EUID -ne 0 ]]; then
      log_fail 'Setup tools are missing. Run: sudo vm-init prepare'
      return 1
    fi
    log_step "Preparing configuration tools: ${missing[*]}"
    # Native APT waiting handles the initial bootstrap before Python exists.
    run_maybe_timeout apt-get -o "DPkg::Lock::Timeout=${VM_INIT_APT_LOCK_TIMEOUT:-1800}" update -q || return 1
    run_maybe_timeout apt-get -o "DPkg::Lock::Timeout=${VM_INIT_APT_LOCK_TIMEOUT:-1800}" install -y -q "${missing[@]}" || return 1
  fi
  if (( needs_yq )); then install_config_yq || return 1; fi
  check_config_tools
}

# Ubuntu 22.04 does not provide an APT yq package. Pin and verify the
# upstream binary; compatible preinstalled parsers are left in place.
install_config_yq() (
  local arch checksum temporary
  case "$(uname -m)" in
    x86_64) arch=amd64; checksum=a2c097180dd884a8d50c956ee16a9cec070f30a7947cf4ebf87d5f36213e9ed7 ;;
    aarch64|arm64) arch=arm64; checksum=0e7e1524f68d91b3ff9b089872d185940ab0fa020a5a9052046ef10547023156 ;;
    *) log_fail 'Install mikefarah yq v4 or Python yq for this architecture, then retry prepare'; return 1 ;;
  esac
  temporary=$(mktemp -d) || return 1
  trap 'rm -rf "$temporary"' EXIT
  log_step 'Installing verified yq v4.44.3'
  download_file "https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_${arch}" "$temporary/yq" || return 1
  verify_sha256 "$temporary/yq" "$checksum" || return 1
  install -m 0755 "$temporary/yq" /usr/local/bin/yq
)

check_config_tools() {
  if ! require_commands yq jq python3; then
    log_info 'Prepare configuration tools once with: sudo vm-init prepare'
    return 1
  fi
  local probe
  probe=$(printf 'text: vm-init\nflag: false\nitems: [one]\n' | yq -r '@json' 2>/dev/null) || probe=""
  if ! jq -e '.text == "vm-init" and .flag == false and .items == ["one"]' <<< "$probe" >/dev/null 2>&1; then
    log_fail "Incompatible yq. Install mikefarah yq v4, or Python yq with jq; then retry."
    return 1
  fi
}

validate_config_schema() {
  check_config_tools || return 1
  local encoded errors
  if ! encoded=$(yq -r '@json' "$CONFIG" 2>/dev/null) \
      || ! jq -se 'length == 1 and (.[0] | type == "object")' <<< "$encoded" >/dev/null 2>&1; then
    log_fail "Config is not valid YAML: expected one mapping in ${CONFIG}"
    return 1
  fi
  errors=$(jq -r '["apt","ufw","fail2ban","kernel","dns","docker","python","github_tools","github_releases","yazi","shell"][] as $m | select(.[$m] != null and (.[$m] | type) != "object") | "\($m) must be object"' <<< "$encoded") || return 1
  if [[ -n "$errors" ]]; then log_fail "$errors"; return 1; fi
  errors=$(jq -r '

    def check($path; $expected_type):
      (try getpath($path) catch null) as $v |
      if $v != null and ($v | type) != $expected_type then
        "\($path | join(".")) must be \($expected_type)"
      else empty end;
    . as $config |
    ["apt","ufw","fail2ban","kernel","dns","docker","python","github_tools","github_releases","yazi","shell"] as $modules |
    ($modules[] as $m | check([$m]; "object")),
    ($modules[] as $m | select(($config[$m] | type) == "object") |
      select($config[$m] | has("enabled")) |
      select(($config[$m].enabled | type) != "boolean") | "\($m).enabled must be boolean (true or false)"),
    ([ ["ufw","ipv6"], ["kernel","mitigations_off"], ["shell","fisher"],
       ["shell","tide"], ["shell","zoxide"], ["shell","direnv"],
       ["github_tools","gh"], ["github_tools","act"] ][] as $p | check($p; "boolean")),
    ([ ["apt","packages"], ["ufw","defaults"], ["fail2ban","jails"],
       ["github_releases","custom"], ["shell","aliases"] ][] as $p | check($p; "object")),
    ([ ["users"], ["ufw","allow"], ["dns","bootstrap"], ["fail2ban","ignoreip"],
       ["python","tools"], ["github_releases","generic"] ][] as $p | check($p; "array")),
    ([ ["dns","server"], ["dns","listen_address"], ["shell","default_shell"],
       ["fail2ban","backend"], ["fail2ban","banaction"] ][] as $p | check($p; "string")),
    (if (.apt.packages | type) == "object" then
       .apt.packages | to_entries[] |
       if (.value | type) != "array" then "apt.packages.\(.key) must be array"
       elif any(.value[]; type != "string") then "apt.packages.\(.key) must contain package names"
       else empty end else empty end),
    (if (.users | type) == "array" then .users[] |
       select(type != "string" or (test("^[a-z_][a-zA-Z0-9_-]*[$]?$") | not)) |
       "users must contain account names" else empty end),
    (if (.shell.aliases | type) == "object" then .shell.aliases | to_entries[] |
       select((.key | test("^[a-zA-Z_][a-zA-Z0-9_-]*$") | not) or (.value | type) != "string") |
       "shell.aliases must map plain alias names to command strings" else empty end),
    (if (.github_releases.custom | type) == "object" then .github_releases.custom | to_entries[] |
       select((.value | type) != "boolean") | "github_releases.custom.\(.key) must be boolean" else empty end),
    (if (.fail2ban.jails | type) == "object" then .fail2ban.jails | to_entries[] |
       if .key != "sshd" then "fail2ban.jails.\(.key) is not supported (use sshd)"
       elif (.value | type) != "object" then "fail2ban.jails.sshd must be object"
       elif (.value | has("enabled")) and (.value.enabled | type) != "boolean" then "fail2ban.jails.sshd.enabled must be boolean"
       else empty end else empty end),
    (if (.github_releases.generic | type) == "array" then .github_releases.generic | to_entries[] |
       select((.value | type) != "object") | "github_releases.generic[\(.key)] must be object" else empty end),
    (if (.python.tools | type) == "array" then .python.tools[] | select(type != "string") | "python.tools must contain strings" else empty end),
    (if (.dns.bootstrap | type) == "array" then .dns.bootstrap[] | select(type != "string") | "dns.bootstrap must contain IP address strings" else empty end),
    (if (.fail2ban.ignoreip | type) == "array" then .fail2ban.ignoreip[] | select(type != "string") | "fail2ban.ignoreip must contain address strings" else empty end),
    (if (.ufw.allow | type) == "array" then .ufw.allow[] |
       if (type != "string" and type != "number") then "ufw.allow must contain ports or application names"
       elif (tostring | test("^[A-Za-z0-9][A-Za-z0-9 /:_-]*$") | not) then "ufw.allow contains an invalid rule"
       else empty end else empty end),
    (select(.shell.default_shell != null and .shell.default_shell != "fish" and .shell.default_shell != "bash") | "shell.default_shell must be fish or bash"),
    (select(.shell.tide == true and .shell.fisher != true) | "shell.tide requires shell.fisher: true"),
    (select(.shell.default_shell == "bash" and (.shell.fisher == true or .shell.tide == true)) | "Fisher and Tide require shell.default_shell: fish"),
    (paths(strings) as $p | getpath($p) | select(explode | any(. == 0 or . == 10 or . == 13)) | "Configuration values must not contain line breaks or NUL characters")
  ' <<< "$encoded") || return 1
  if [[ -n "$errors" ]]; then
    while IFS= read -r error; do log_fail "$error"; done <<< "$errors"
    return 1
  fi
  VM_INIT_CONFIG_JSON=$(jq -c . <<< "$encoded")
}

resolve_target_users() {
  local selection="${VM_INIT_USER_OPTION:-}" user accounts count
  if [[ "${VM_INIT_ALL_USERS:-0}" == 1 ]]; then
    selection="root $(human_users | cut -d: -f1 | paste -sd' ' -)"
  elif [[ -z "$selection" ]]; then
    selection=$(yq -r '.users // [] | .[]' "$CONFIG" | paste -sd' ' -)
  fi
  if [[ -z "$selection" ]]; then
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
      selection="$SUDO_USER"
    elif [[ $EUID -ne 0 ]]; then
      selection=$(id -un)
    elif command -v getent >/dev/null 2>&1; then
      accounts=$(human_users)
      count=$(printf '%s\n' "$accounts" | awk 'NF { n++ } END { print n+0 }')
      if [[ "$count" == 1 ]]; then selection="${accounts%%:*}"; fi
    fi
  fi
  if [[ -z "$selection" ]]; then
    log_fail "Choose an account with --user <name>, users: [name] in config, or --all-users."
    return 1
  fi
  selection="${selection//,/ }"
  VM_INIT_TARGET_USERS=""
  for user in $selection; do
    if [[ ! "$user" =~ ^[a-z_][a-zA-Z0-9_-]*\$?$ ]]; then
      log_fail "Invalid account name: ${user}"
      return 1
    fi
    if command -v getent >/dev/null 2>&1; then
      if ! getent passwd "$user" >/dev/null; then
        log_fail "Account does not exist: ${user}"
        return 1
      fi
    elif [[ "${VM_INIT_DRY_RUN:-0}" != 1 ]]; then
      log_fail "getent is required to resolve accounts"
      return 1
    fi
    [[ " $VM_INIT_TARGET_USERS " == *" $user "* ]] || VM_INIT_TARGET_USERS+="${VM_INIT_TARGET_USERS:+ }${user}"
  done
  [[ -n "$VM_INIT_TARGET_USERS" ]] || { log_fail 'Select at least one account with --user'; return 1; }
  export VM_INIT_TARGET_USERS
}

# Persist the exact config and choices used for a mutation, never shell code.
save_run_context() {
  local run_dir="$VM_INIT_STATE_DIR/runs/$VM_INIT_RUN_ID" users
  VM_INIT_PREVIOUS_CONFIG=$(state_get last.config 2>/dev/null || true)
  export VM_INIT_PREVIOUS_CONFIG
  mkdir -p "$run_dir" || return 1
  chmod 700 "$VM_INIT_STATE_DIR/runs" "$run_dir"
  users=$(printf '%s\n' "${VM_INIT_TARGET_USERS:-}" | jq -R 'split(" ") | map(select(length > 0))')
  jq --argjson users "$users" '. + {users: $users}' <<< "$VM_INIT_CONFIG_JSON" > "$run_dir/config.json"
  chmod 600 "$run_dir/config.json"
  VM_INIT_RETRY_CONFIG="$run_dir/config.json"
  export VM_INIT_CONFIG_FINGERPRINT
  VM_INIT_CONFIG_FINGERPRINT=$(_sha256_of "$VM_INIT_RETRY_CONFIG")
  state_set last.run "$VM_INIT_RUN_ID"
  state_set last.config "$VM_INIT_RETRY_CONFIG"
}
