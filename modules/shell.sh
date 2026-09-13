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
  local user="$1" fish_cmd="$2"
  # shellcheck disable=SC2016  # "$1" is sh's positional arg, not ours
  if [[ "$user" == "root" ]]; then
    run_quiet sh -c 'unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME XDG_RUNTIME_DIR; cd / && exec fish -c "$1"' _ "$fish_cmd" < /dev/null
  else
    run_quiet sudo -u "$user" -H sh -c 'unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME XDG_RUNTIME_DIR; cd / && exec fish -c "$1"' _ "$fish_cmd" < /dev/null
  fi
}

# True when the `fisher` function is available for <user>. Probed per account:
# Fisher installs into ~/.config/fish/functions, so root having it says nothing
# about a human user (who may have been added after the first run, or had their
# home recreated). `functions -q` triggers fish's autoloader and stays silent.
fisher_present_for() {
  run_fish_as "$1" 'functions -q fisher' >/dev/null 2>&1
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
    log_current "fisher (${user})"
    return 0
  fi

  if [[ "$(yq_get '.shell.tide' false "$CONFIG")" == true ]]; then
    run_fish_as "$user" 'functions -q tide || fisher install IlanCosman/tide@v6' || return 1
  fi
  log_step "Updating Fisher plugins (${user})"
  if run_fish_as "$user" 'fisher update'; then
    log_upgraded "fisher plugins (${user})"
  else
    log_warn "fisher update (${user}) returned non-zero"
  fi
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
    chmod 0644 "$tempfile"
    mv -f "$tempfile" "$destination"
  ' _ "$2"
}

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
    check+='test "$actual" = "$expected"; or exit 1; '
  done < <(yq -r '.shell.aliases // {} | keys | .[]' "$CONFIG")
  [[ -n "$check" ]] || return 0
  run_fish_as "$user" "$check"
}

install_shell() {
  require_commands chsh getent awk || return 1
  local default_shell shell_path user home_dir managed temp packages=()
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
    if ! write_shell_file "$user" "$managed" < "$temp"; then
      rm -f "$temp"
      log_fail "${user} cannot write ${managed}; check that this account owns its shell configuration directory"
      return 1
    fi
    if [[ "$default_shell" == bash ]]; then
      local hook
      hook="source $(shell_command "$managed") # vm-init"
      # shellcheck disable=SC2016 # expanded by the target account's shell
      run_as_user "$user" sh -c 'grep -qxF "$1" "$2" 2>/dev/null || printf "\n%s\n" "$1" >> "$2"' _ "$hook" "$home_dir/.bashrc" || { rm -f "$temp"; return 1; }
    fi
    if ! chsh -s "$shell_path" "$user"; then rm -f "$temp"; log_fail "Failed to change shell for $user"; return 1; fi
    if [[ "$default_shell" == fish && "$(yq_get '.shell.fisher' false "$CONFIG")" == true ]]; then
      setup_fisher_for "$user" "$home_dir" || { rm -f "$temp"; return 1; }
    fi
    if [[ "$default_shell" == fish ]] && ! fish_aliases_match_for "$user"; then
      log_warn "${user}: an existing Fish setting overrides a managed alias"
      vm_init_note "Review ${home_dir}/.config/fish/config.fish for aliases that override vm-init settings, then run status."
    fi
    log_ok "${default_shell} configured for ${user}"
  done < <(target_users)
  rm -f "$temp"
  vm_init_note "Start a new session to use ${default_shell} (${VM_INIT_TARGET_USERS})."
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
