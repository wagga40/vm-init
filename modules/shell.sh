#!/usr/bin/env bash
# Fish shell configuration module.
# Reads: CONFIG (path to vm-init.yml)

# Run `fish -c <cmd>` as <user>.
#
# Account-specific process setup:
#   * The `cd /` is not cosmetic: vm-init normally runs with cwd=/root (mode
#     0700), which the target user cannot open, and fish then aborts the
#     command with "Unable to open the current working directory".
#   * `</dev/null` is mandatory. Callers drive these commands from
#     `while read ... < <(human_users)` loops, and fisher reads plugin names
#     from stdin when it isn't a tty — so without this it swallows the rest of
#     the user list ("fisher: Plugin not installed: bob:/home/bob") and every
#     account after the first is silently skipped.
#   * Hopping through `sh -c` (rather than a subshell `cd`) keeps sudo as the
#     outer command so run_quiet still applies its timeout.
#   * sudo can preserve the invoking account's XDG paths even with -H.
#     Clear those paths so Fish and its plugins use the selected account's
#     home, matching the location of the managed configuration files.
run_fish_as() {
  local user="$1" fish_cmd="$2" runner=run_quiet
  # A probe prints its own concise mismatch; do not dump generated Fish code.
  if [[ "${3:-}" == probe ]]; then runner=run_maybe_timeout; fi
  # shellcheck disable=SC2016  # "$1" is sh's positional arg, not ours
  if [[ "$user" == "root" ]]; then
    "$runner" sh -c 'unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME XDG_RUNTIME_DIR; cd / && exec fish -c "$1"' _ "$fish_cmd" < /dev/null
  else
    "$runner" sudo -u "$user" -H sh -c 'unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME XDG_RUNTIME_DIR; cd / && exec fish -c "$1"' _ "$fish_cmd" < /dev/null
  fi
}

# True when the `fisher` function is available for <user>. Probed per account:
# Fisher installs into ~/.config/fish/functions, so root having it says nothing
# about a human user (who may have been added after the first run, or had their
# home recreated). `functions -q` triggers fish's autoloader and stays silent.
fisher_present_for() {
  run_fish_as "$1" 'functions -q fisher' probe >/dev/null 2>&1
}

install_fisher_tide() {
  local user="$1"
  local home_dir="$2"

  run_as_user "$user" mkdir -p "${home_dir}/.config/fish" || return 1

  local fisher_tmp
  fisher_tmp=$(mktemp -d) || return 1
  chmod 755 "$fisher_tmp"
  local fisher_url="https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish"
  if ! run_quiet download_file "$fisher_url" "$fisher_tmp/fisher.fish"; then
    rm -rf "$fisher_tmp"
    log_fail "Failed to download fisher.fish from ${fisher_url}"
    return 1
  fi

  local fisher_enabled tide_enabled
  fisher_enabled=$(yq_get '.shell.fisher' true "$CONFIG")
  tide_enabled=$(yq_get '.shell.tide' false "$CONFIG")

  local fish_cmd=""
  if [[ "$fisher_enabled" == "true" ]]; then
    chmod 644 "$fisher_tmp/fisher.fish"
    fish_cmd="source $(fish_quote "$fisher_tmp/fisher.fish") && fisher install jorgebucaran/fisher"
    if [[ "$tide_enabled" == "true" ]]; then
      fish_cmd="${fish_cmd} && fisher install IlanCosman/tide@v6"
    fi
  fi

  if [[ -z "$fish_cmd" ]]; then
    rm -rf "$fisher_tmp"
    return 0
  fi

  if ! run_fish_as "$user" "$fish_cmd"; then
    rm -rf "$fisher_tmp"
    log_fail "Failed to install Fisher/Tide for ${user}"
    return 1
  fi

  rm -rf "$fisher_tmp"
}

# Bring one account to the desired Fisher state: install when the account has
# no fisher yet, otherwise refresh its plugins.
setup_fisher_for() {
  local user="$1" home_dir="$2"

  if should_force || ! fisher_present_for "$user"; then
    log_step "Installing selected Fisher plugins (${user})"
    install_fisher_tide "$user" "$home_dir" || return 1
    log_installed "Fisher plugins (${user})"
    return 0
  fi

  if ! should_upgrade; then
    if [[ "$(yq_get '.shell.tide' false "$CONFIG")" == true ]]; then
      run_fish_as "$user" 'functions -q tide || fisher install IlanCosman/tide@v6' || return 1
    fi
    log_current "fisher (${user})"
    return 0
  fi

  if [[ "$(yq_get '.shell.tide' false "$CONFIG")" == true ]]; then
    run_fish_as "$user" 'functions -q tide || fisher install IlanCosman/tide@v6' || return 1
  fi
  log_step "Updating Fisher plugins (${user})"
  local before after
  before=$(fish_plugin_fingerprint "$user" "$home_dir" 2>/dev/null || true)
  if run_fish_as "$user" 'fisher update'; then
    after=$(fish_plugin_fingerprint "$user" "$home_dir" 2>/dev/null || true)
    if [[ -n "$before" && "$before" == "$after" ]]; then log_current "fisher plugins (${user})"
    else log_upgraded "fisher plugins (${user})"; fi
  else
    log_warn "fisher update (${user}) returned non-zero"
  fi
}

fish_plugin_fingerprint() {
  run_as_user "$1" python3 -c '
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1]) / ".config/fish"
paths = [root / "fish_plugins"]
for name in ("functions", "completions", "conf.d"):
    paths.extend((root / name).rglob("*"))
digest = hashlib.sha256()
for path in sorted(paths):
    if path.is_file():
        digest.update(str(path.relative_to(root)).encode() + b"\0" + path.read_bytes() + b"\0")
print(digest.hexdigest())
' "$2"
}

fish_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\'/\\\'}"
  printf "'%s'" "$value"
}

shell_required_packages() {
  yq_get '.shell.default_shell' fish "$CONFIG"
  if [[ "$(yq_get '.shell.zoxide' false "$CONFIG")" == true ]]; then echo zoxide; fi
  if [[ "$(yq_get '.shell.direnv' false "$CONFIG")" == true ]]; then echo direnv; fi
  local value cmd
  while read -r value; do
    cmd="${value%% *}"
    case "$cmd" in bat|batcat) echo bat ;; lsd) echo lsd ;; esac
  done < <(yq -r '.shell.aliases // {} | to_entries | .[].value' "$CONFIG")
}

shell_alias_value() {
  local key="$1" value
  value=$(yq -r ".shell.aliases[\"$key\"]" "$CONFIG")
  if [[ "${value%% *}" == bat ]] && ! is_installed bat && is_installed batcat; then
    value="batcat${value#bat}"
  fi
  printf '%s\n' "$value"
}

render_shell_config() {
  local shell="$1" key value cmd
  echo '# Managed by vm-init. Edit aliases and integrations in vm-init.yml.'
  while read -r key; do
    [[ -n "$key" ]] || continue
    value=$(shell_alias_value "$key") || return 1
    cmd="${value%% *}"
    if ! is_installed "$cmd"; then
      log_fail "Alias ${key} requires ${cmd}; add its package to apt.packages.extra"
      return 1
    fi
    if [[ "$shell" == fish ]]; then
      printf 'alias -- %s %s\n' "$(fish_quote "$key")" "$(fish_quote "$value")"
    else
      printf 'alias %s=%q\n' "$key" "$value"
    fi
  done < <(yq -r '.shell.aliases // {} | keys | .[]' "$CONFIG")
  if [[ "$shell" == fish ]]; then
    echo 'fish_add_path -g /usr/local/bin'
    if [[ "$(yq_get '.shell.zoxide' false "$CONFIG")" == true ]]; then echo 'zoxide init fish | source'; fi
    if [[ "$(yq_get '.shell.direnv' false "$CONFIG")" == true ]]; then echo 'direnv hook fish | source'; fi
  else
    # shellcheck disable=SC2016
    if [[ "$(yq_get '.shell.zoxide' false "$CONFIG")" == true ]]; then echo 'eval "$(zoxide init bash)"'; fi
    # shellcheck disable=SC2016
    if [[ "$(yq_get '.shell.direnv' false "$CONFIG")" == true ]]; then echo 'eval "$(direnv hook bash)"'; fi
  fi
}

shell_managed_path() {
  if [[ "$1" == fish ]]; then printf '%s/.config/fish/conf.d/90-vm-init.fish\n' "$2"
  else printf '%s/.config/vm-init/bash.sh\n' "$2"; fi
}

run_as_user() {
  local user="$1"
  shift
  # shellcheck disable=SC2016 # positional arguments belong to the child shell
  if [[ "$user" == root ]]; then
    sh -c 'cd / && exec "$@"' _ "$@"
  else
    sudo -u "$user" -H sh -c 'cd / && exec "$@"' _ "$@"
  fi
}

write_shell_file() {
  # Drop privileges before following any path inside a user's home. Pipe the
  # generated file in so the source temporary file can remain private to root.
  # shellcheck disable=SC2016 # this script runs as the target account
  run_as_user "$1" bash -c '
    set -e
    destination=$1
    if [[ -d "$destination" ]]; then echo "Expected a file: $destination" >&2; exit 1; fi
    mkdir -p "$(dirname "$destination")"
    tempfile=$(mktemp "$(dirname "$destination")/.vm-init.XXXXXX")
    trap '\''rm -f "$tempfile"'\'' EXIT
    cat > "$tempfile"
    if cmp -s "$tempfile" "$destination"; then exit 0; fi
    if [[ -f "$destination" ]]; then cp -p "$destination" "${destination}.vm-init.bak"; fi
    chmod 0644 "$tempfile"
    mv -f "$tempfile" "$destination"
  ' _ "$2"
}

bash_aliases_match_for() {
  local user="$1" home_dir="$2" key value check=''
  while read -r key; do
    [[ -n "$key" ]] || continue
    value=$(shell_alias_value "$key") || return 1
    check+="actual=\$(alias $(shell_command "$key") 2>/dev/null); alias $(shell_command "$key=$value"); expected=\$(alias $(shell_command "$key")); "
    # shellcheck disable=SC2016 # expanded by the account's disposable Bash
    check+='[[ "$actual" == "$expected" ]] || exit 1; '
  done < <(yq -r '.shell.aliases // {} | keys | .[]' "$CONFIG")
  [[ -n "$check" ]] || return 0
  run_as_user "$user" bash --noprofile --rcfile "$home_dir/.bashrc" -ic "$check" </dev/null >/dev/null 2>&1
}

shell_observe_spec() {
  local user="$1" spec="$2" actual file hash hook wanted_hook
  actual=$(getent passwd "$user" | awk -F: '{print $7}') || return 1
  [[ -n "$actual" ]] || return 1
  file=$(jq -r '.file' <<< "$spec")
  hash=$(reconcile_file_value "$file") || return 1
  wanted_hook=$(jq -r '.hook' <<< "$spec")
  hook="$wanted_hook"
  if [[ -n "$wanted_hook" ]] && ! grep -qxF "$wanted_hook" "$(jq -r '.home' <<< "$spec")/.bashrc" 2>/dev/null; then hook=absent; fi
  jq -cS --arg shell "$actual" --arg content "$hash" --arg hook "$hook" \
    '.shell=$shell | .content=$content | .hook=$hook' <<< "$spec"
}

inspect_shell_account() {
  local user="$1" home_dir="$2" expected="$3" shell="$4" shell_path="$5"
  local managed hook='' saved previous prior_observed legacy=0 identity
  managed=$(shell_managed_path "$shell" "$home_dir")
  local VM_INIT_RESOURCE_LABEL="shell configuration for $user ($managed)"
  export VM_INIT_RESOURCE_LABEL
  if [[ "$shell" == bash ]]; then hook="source $(shell_command "$managed") # vm-init"; fi
  identity=$(getent passwd "$user" | awk -F: '{print $1 ":" $3 ":" $6}') || return 1
  SHELL_KEY="shell.account.$(printf '%s' "$identity" | _sha256_stdin)"
  SHELL_DESIRED=$(jq -cnS --arg shell "$shell_path" --arg file "$managed" --arg content "$(reconcile_file_value "$expected")" \
    --arg home "$home_dir" --arg hook "$hook" '{shell:$shell,file:$file,content:$content,home:$home,hook:$hook}') || return 1
  SHELL_OBSERVED=$(shell_observe_spec "$user" "$SHELL_DESIRED") || return 1
  SHELL_INITIAL_OBSERVED="$SHELL_OBSERVED"
  saved=$(reconcile_load "$SHELL_KEY") || return 1
  if [[ "$saved" != null && "$SHELL_OBSERVED" != "$SHELL_DESIRED" ]]; then
    previous=$(jq -r '.desired' <<< "$saved")
    prior_observed=$(shell_observe_spec "$user" "$previous") || return 1
    if [[ "$prior_observed" == "$(jq -r '.observed' <<< "$saved")" ]]; then SHELL_OBSERVED="$prior_observed"; fi
  fi
  if [[ -e "$managed" || -L "$managed" ]] || reconcile_account_legacy shell "$user"; then legacy=1; fi
  reconcile_decide "$SHELL_KEY" "$SHELL_DESIRED" "$SHELL_OBSERVED" "$legacy"
}

inspect_shell() (
  local shell shell_path temp user home_dir dependency
  shell=$(yq_get '.shell.default_shell' fish "$CONFIG")
  shell_path="${VM_INIT_SHELL_PATH:-/usr/bin/$shell}"
  temp=$(mktemp) || return 1
  trap 'rm -f "$temp"' EXIT
  while read -r dependency; do
    if [[ "$dependency" == bat ]] && is_installed batcat; then continue; fi
    if ! is_installed "$dependency"; then
      reconcile_report "shell.dependencies.$dependency" pending "$dependency installed" missing 'required shell dependency'
    fi
  done < <(shell_required_packages | sort -u)
  if ! render_shell_config "$shell" > "$temp"; then
    reconcile_report shell.dependencies pending 'required shell dependencies' missing 'install dependencies before rendering'; return 0
  fi
  while IFS=: read -r user home_dir; do
    inspect_shell_account "$user" "$home_dir" "$temp" "$shell" "$shell_path" || return 1
    if [[ "$shell" == fish && -x "$shell_path" ]]; then
      if [[ "$RECONCILE_ACTION" == unchanged ]] && ! fish_aliases_match_for "$user"; then
        reconcile_report "$SHELL_KEY.aliases" drifted 'configured aliases' 'different effective aliases' "review startup files for $user"
      fi
      if [[ "$(yq_get '.shell.fisher' false "$CONFIG")" == true ]] && ! fisher_present_for "$user"; then
        reconcile_report "$SHELL_KEY.fisher" pending installed missing "Fisher is missing for $user"
      fi
      if [[ "$(yq_get '.shell.tide' false "$CONFIG")" == true ]] && ! run_fish_as "$user" 'functions -q tide' probe >/dev/null 2>&1; then
        reconcile_report "$SHELL_KEY.tide" pending installed missing "Tide is missing for $user"
      fi
    elif [[ "$RECONCILE_ACTION" == unchanged && "$shell" == bash && -f "$home_dir/.bashrc" ]] && ! bash_aliases_match_for "$user" "$home_dir"; then
      reconcile_report "$SHELL_KEY.aliases" drifted 'configured aliases' 'different effective aliases' "review startup files for $user"
    fi
  done < <(target_users)
)

fish_aliases_match_for() {
  local user="$1" key value check='' quoted_key
  while read -r key; do
    [[ -n "$key" ]] || continue
    value=$(shell_alias_value "$key") || return 1
    quoted_key=$(fish_quote "$key")
    # Compare function definitions after normal Fish startup. Defining the
    # expected alias inside this disposable shell never invokes its command.
    check+="$(printf 'set -l actual (functions %s | string match -rv "^#"); alias -- %s %s; set -l expected (functions %s | string match -rv "^#"); ' "$quoted_key" "$quoted_key" "$(fish_quote "$value")" "$quoted_key")"
    # shellcheck disable=SC2016 # these variables belong to Fish
    check+='test "$actual" = "$expected"; or begin; '
    check+="printf '%s\\n' $(fish_quote "$user: alias $key does not match the configured command") >&2; exit 1; end; "
  done < <(yq -r '.shell.aliases // {} | keys | .[]' "$CONFIG")
  [[ -n "$check" ]] || return 0
  run_fish_as "$user" "$check" probe
}

install_shell() {
  require_commands chsh getent awk || return 1
  local default_shell shell_path user home_dir managed temp packages=() changed_users=''
  default_shell=$(yq_get '.shell.default_shell' fish "$CONFIG")
  mapfile -t packages < <(shell_required_packages | sort -u)
  log_step "Preparing shell dependencies: ${packages[*]}"
  ensure_apt_packages "${packages[@]}" || return 1
  shell_path="${VM_INIT_SHELL_PATH:-/usr/bin/$default_shell}"
  [[ -x "$shell_path" ]] || { log_fail "Shell missing: $shell_path"; return 1; }
  temp=$(mktemp) || return 1
  if ! render_shell_config "$default_shell" > "$temp"; then rm -f "$temp"; return 1; fi
  if [[ "$default_shell" == fish ]]; then fish -n "$temp" || { rm -f "$temp"; return 1; }
  else bash -n "$temp" || { rm -f "$temp"; return 1; }; fi
  while IFS=: read -r user home_dir; do
    [[ -n "$user" ]] || continue
    managed=$(shell_managed_path "$default_shell" "$home_dir")
    inspect_shell_account "$user" "$home_dir" "$temp" "$default_shell" "$shell_path" || { rm -f "$temp"; return 1; }
    if [[ "$RECONCILE_ACTION" == drift ]]; then continue; fi
    local changed=false
    if [[ "$RECONCILE_ACTION" == apply ]]; then
      if [[ "$(shell_observe_spec "$user" "$SHELL_DESIRED")" != "$SHELL_INITIAL_OBSERVED" ]]; then
        rm -f "$temp"; log_fail "${user}: shell settings changed during inspection"; return 1
      fi
      reconcile_begin "$SHELL_KEY" "$SHELL_DESIRED" "$SHELL_OBSERVED" || { rm -f "$temp"; return 1; }
      if ! write_shell_file "$user" "$managed" < "$temp"; then
        rm -f "$temp"
        log_fail "${user} cannot write ${managed}; check that this account owns its shell configuration directory"
        return 1
      fi
      reconcile_checkpoint "$SHELL_KEY" "$(shell_observe_spec "$user" "$SHELL_DESIRED")" || { rm -f "$temp"; return 1; }
      if [[ "$default_shell" == bash ]]; then
        local hook
        hook="source $(shell_command "$managed") # vm-init"
        # shellcheck disable=SC2016 # expanded by the target account's shell
        run_as_user "$user" sh -c 'grep -qxF "$1" "$2" 2>/dev/null || printf "\n%s\n" "$1" >> "$2"' _ "$hook" "$home_dir/.bashrc" || { rm -f "$temp"; return 1; }
        reconcile_checkpoint "$SHELL_KEY" "$(shell_observe_spec "$user" "$SHELL_DESIRED")" || { rm -f "$temp"; return 1; }
      fi
      if [[ "$(getent passwd "$user" | awk -F: '{print $7}')" != "$shell_path" ]]; then
        if ! chsh -s "$shell_path" "$user"; then rm -f "$temp"; log_fail "Failed to change shell for $user"; return 1; fi
      fi
      changed=true
      changed_users+="${changed_users:+, }$user"
    fi
    if [[ "$default_shell" == fish && "$(yq_get '.shell.fisher' false "$CONFIG")" == true ]]; then
      local plugins_before plugins_after
      plugins_before=$(fish_plugin_fingerprint "$user" "$home_dir" 2>/dev/null || true)
      setup_fisher_for "$user" "$home_dir" || { rm -f "$temp"; return 1; }
      plugins_after=$(fish_plugin_fingerprint "$user" "$home_dir" 2>/dev/null || true)
      if [[ -n "$plugins_before" && "$plugins_before" != "$plugins_after" ]]; then
        reconcile_report "$SHELL_KEY.plugins" in_sync installed installed 'plugin files changed' true
        if [[ "$changed" != true ]]; then changed_users+="${changed_users:+, }$user"; fi
      fi
    fi
    if { [[ "$default_shell" == fish ]] && ! fish_aliases_match_for "$user"; } \
      || { [[ "$default_shell" == bash ]] && ! bash_aliases_match_for "$user" "$home_dir"; }; then
      log_info "${user}: some Fish aliases differ from your configuration"
      vm_init_note "Review ${user}'s shell startup files for aliases that override vm-init settings, then run status." action 'review alias overrides'
      reconcile_report "$SHELL_KEY.aliases" drifted 'configured aliases' 'startup override' 'external shell settings override managed aliases'
    fi
    SHELL_OBSERVED=$(shell_observe_spec "$user" "$SHELL_DESIRED") || { rm -f "$temp"; return 1; }
    if [[ "$SHELL_OBSERVED" != "$SHELL_DESIRED" ]]; then rm -f "$temp"; log_fail "${user}: shell changes did not verify"; return 1; fi
    reconcile_accept "$SHELL_KEY" "$SHELL_DESIRED" "$SHELL_OBSERVED" "$changed" || { rm -f "$temp"; return 1; }
    if [[ "$changed" == true ]]; then log_ok "${default_shell} configured for ${user}"
    else log_ok "${default_shell} unchanged for ${user}"; fi
  done < <(target_users)
  rm -f "$temp"
  if [[ -n "$changed_users" ]]; then vm_init_note "Start a new session to use ${default_shell} (${changed_users})." session; fi
}

verify_shell() {
  require_commands getent || return 1
  local default_shell shell_path user home_dir actual managed expected rc=0
  default_shell=$(yq_get '.shell.default_shell' fish "$CONFIG")
  shell_path="${VM_INIT_SHELL_PATH:-/usr/bin/$default_shell}"
  expected=$(mktemp) || return 1
  local dependency
  while read -r dependency; do
    if [[ "$dependency" == bat ]] && is_installed batcat; then continue; fi
    if ! is_installed "$dependency"; then log_fail "Shell dependency is missing: $dependency"; rc=1; fi
  done < <(shell_required_packages | sort -u)
  if ! render_shell_config "$default_shell" > "$expected"; then rm -f "$expected"; return 1; fi
  while IFS=: read -r user home_dir; do
    [[ -n "$user" ]] || continue
    actual=$(getent passwd "$user" | awk -F: '{print $7}')
    if [[ "$actual" != "$shell_path" ]]; then log_fail "${user}: login shell is ${actual}, expected ${shell_path}"; rc=1; fi
    managed=$(shell_managed_path "$default_shell" "$home_dir")
    if ! cmp -s "$expected" "$managed"; then
      log_fail "${user}: managed aliases or integrations differ from configuration"; rc=1
    elif [[ "$default_shell" == bash ]] && ! grep -qxF "source $(shell_command "$managed") # vm-init" "$home_dir/.bashrc"; then
      log_fail "${user}: Bash configuration does not load vm-init settings"; rc=1
    else log_ok "${user}: managed shell settings match"; fi
    if [[ "$default_shell" == fish ]] && ! fish_aliases_match_for "$user"; then
      log_fail "${user}: active aliases differ; review ${home_dir}/.config/fish/config.fish"; rc=1
    fi
    if [[ "$default_shell" == bash ]] && ! bash_aliases_match_for "$user" "$home_dir"; then
      log_fail "${user}: active Bash aliases differ from configuration"; rc=1
    fi
    if [[ "$default_shell" == fish && "$(yq_get '.shell.fisher' false "$CONFIG")" == true ]] && ! fisher_present_for "$user"; then
      log_fail "${user}: Fisher is missing"; rc=1
    fi
    if [[ "$default_shell" == fish && "$(yq_get '.shell.tide' false "$CONFIG")" == true ]] && ! run_fish_as "$user" 'functions -q tide'; then
      log_fail "${user}: Tide is missing"; rc=1
    fi
  done < <(target_users)
  rm -f "$expected"
  return "$rc"
}
