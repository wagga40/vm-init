#!/usr/bin/env bash
# Fish shell configuration module.
# Reads: CONFIG (path to vm-init.yml)

# Run `fish -c <cmd>` as <user>.
#
# Three wrinkles this handles:
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
run_fish_as() {
  local user="$1" fish_cmd="$2"
  # shellcheck disable=SC2016  # "$1" is sh's positional arg, not ours
  if [[ "$user" == "root" ]]; then
    run_quiet sh -c 'cd / && exec fish -c "$1"' _ "$fish_cmd" < /dev/null
  else
    run_quiet sudo -u "$user" sh -c 'cd / && exec fish -c "$1"' _ "$fish_cmd" < /dev/null
  fi
}

# True when the `fisher` function is available for <user>. Probed per account:
# Fisher installs into ~/.config/fish/functions, so root having it says nothing
# about a human user (who may have been added after the first run, or had their
# home recreated). `functions -q` triggers fish's autoloader and stays silent.
fisher_present_for() {
  local user="$1"
  if [[ "$user" == "root" ]]; then
    sh -c 'cd / && exec fish -c "functions -q fisher"' < /dev/null >/dev/null 2>&1
  else
    sudo -u "$user" sh -c 'cd / && exec fish -c "functions -q fisher"' < /dev/null >/dev/null 2>&1
  fi
}

install_fisher_tide() {
  local user="$1"
  local home_dir="$2"

  mkdir -p "${home_dir}/.config/fish"
  if [[ "$user" != "root" ]]; then
    chown -R "$user:$user" "${home_dir}/.config" 2>/dev/null || true
  fi

  local fisher_url="https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish"
  if ! run_quiet download_file "$fisher_url" /tmp/fisher.fish; then
    log_fail "Failed to download fisher.fish from ${fisher_url}"
    return 1
  fi

  local fisher_enabled tide_enabled
  fisher_enabled=$(yq_get '.shell.fisher' true "$CONFIG")
  tide_enabled=$(yq_get '.shell.tide' true "$CONFIG")

  local fish_cmd=""
  if [[ "$fisher_enabled" == "true" ]]; then
    fish_cmd="source /tmp/fisher.fish && fisher install jorgebucaran/fisher"
    if [[ "$tide_enabled" == "true" ]]; then
      fish_cmd="${fish_cmd} && fisher install IlanCosman/tide@v6"
    fi
  fi

  if [[ -z "$fish_cmd" ]]; then
    return 0
  fi

  if ! run_fish_as "$user" "$fish_cmd"; then
    log_fail "Failed to install Fisher/Tide for ${user}"
    return 1
  fi

  if [[ "$user" != "root" ]]; then
    chown -R "$user:$user" "${home_dir}/.config" 2>/dev/null || true
  fi
}

# Bring one account to the desired Fisher state: install when the account has
# no fisher yet, otherwise refresh its plugins.
setup_fisher_for() {
  local user="$1" home_dir="$2"

  if should_force || ! fisher_present_for "$user"; then
    log_step "Installing Fisher + Tide (${user})"
    install_fisher_tide "$user" "$home_dir" || return 1
    log_installed "fisher+tide (${user})"
    return 0
  fi

  if ! should_upgrade; then
    log_current "fisher (${user})"
    return 0
  fi

  log_step "Updating Fisher plugins (${user})"
  if run_fish_as "$user" 'fisher update'; then
    log_upgraded "fisher plugins (${user})"
  else
    log_warn "fisher update (${user}) returned non-zero"
  fi
}

install_shell() {
  require_commands usermod chsh getent awk || return 1

  local default_shell
  default_shell=$(yq '.shell.default_shell // "fish"' "$CONFIG")

  local shell_path="/usr/bin/${default_shell}"
  if [[ ! -x "$shell_path" ]]; then
    log_warn "Shell ${default_shell} not found at ${shell_path} (skip)"
    return 1
  fi

  log_step "Setting ${default_shell} as default shell"
  if ! usermod --shell "$shell_path" root; then
    log_fail "Failed to change default shell for root"
    return 1
  fi
  local shell_change_errors=0
  while IFS=: read -r u _home; do
    if ! chsh -s "$shell_path" "$u" 2>/dev/null; then
      log_warn "Failed to change default shell for ${u}"
      shell_change_errors=$((shell_change_errors + 1))
    fi
  done < <(human_users)
  if (( shell_change_errors > 0 )); then
    return 1
  fi

  local fisher_enabled
  fisher_enabled=$(yq_get '.shell.fisher' true "$CONFIG")
  if [[ "$fisher_enabled" == "true" ]]; then
    # Each account is decided on its own state. Gating every account on root's
    # made a user without fisher take the update path and fail with
    # "fish: Unknown command: fisher" (exit 127).
    setup_fisher_for "root" "/root" || return 1

    while IFS=: read -r u home_dir; do
      setup_fisher_for "$u" "$home_dir" || return 1
    done < <(human_users)
  fi

  # Aliases
  log_step "Configuring aliases"
  local alias_keys
  alias_keys=$(yq '.shell.aliases | keys | .[]' "$CONFIG" 2>/dev/null)

  if [[ -n "$alias_keys" ]]; then
    local key value
    while IFS= read -r key; do
      value=$(yq ".shell.aliases.${key}" "$CONFIG")
      local cmd="${value%% *}"
      if ! command -v "$cmd" >/dev/null 2>&1; then
        log_skip "alias ${key} (${cmd} not installed)"
        continue
      fi
      local alias_line="alias ${key}=\"${value}\""

      # Apply to root
      mkdir -p /root/.config/fish
      grep -qxF "$alias_line" /root/.config/fish/config.fish 2>/dev/null \
        || echo "$alias_line" >> /root/.config/fish/config.fish

      while IFS=: read -r u home_dir; do
        mkdir -p "${home_dir}/.config/fish"
        chown -R "$u:$u" "${home_dir}/.config" 2>/dev/null || true
        grep -qxF "$alias_line" "${home_dir}/.config/fish/config.fish" 2>/dev/null \
          || echo "$alias_line" >> "${home_dir}/.config/fish/config.fish"
        chown -R "$u:$u" "${home_dir}/.config" 2>/dev/null || true
      done < <(human_users)
    done <<< "$alias_keys"
  fi

  # Zoxide: hook `zoxide init` into fish and bash. The init script defines
  # `z`/`zi`, so wiring it is what gives the user the `z` alias.
  local zoxide_enabled
  zoxide_enabled=$(yq_get '.shell.zoxide' true "$CONFIG")
  if [[ "$zoxide_enabled" == "true" ]]; then
    if is_installed zoxide; then
      log_step "Configuring zoxide (fish + bash)"
      mkdir -p /etc/fish/conf.d
      echo 'zoxide init fish | source' > /etc/fish/conf.d/zoxide.fish
      # shellcheck disable=SC2016  # $(zoxide init bash) must expand at shell-init time
      echo 'eval "$(zoxide init bash)"' > /etc/profile.d/zoxide.sh
      chmod 0644 /etc/profile.d/zoxide.sh
      # shellcheck disable=SC2016  # $(zoxide init bash) must expand at shell-init time
      local zoxide_bash_line='eval "$(zoxide init bash)"'
      if [[ -f /etc/bash.bashrc ]]; then
        grep -qxF "$zoxide_bash_line" /etc/bash.bashrc \
          || echo "$zoxide_bash_line" >> /etc/bash.bashrc
      fi
      log_ok "zoxide configured"
    else
      log_skip "zoxide (not installed; enable github_releases.generic zoxide)"
    fi
  fi

  # Direnv
  local direnv_enabled
  direnv_enabled=$(yq_get '.shell.direnv' true "$CONFIG")
  if [[ "$direnv_enabled" == "true" ]]; then
    log_step "direnv"
    apt_install_with_report direnv || return 1

    log_step "Configuring direnv and PATH"
    echo 'direnv hook fish | source' > /etc/fish/conf.d/direnv.fish
    echo 'fish_add_path -g /usr/local/bin' > /etc/fish/conf.d/pipx-path.fish
    # shellcheck disable=SC2016  # intentional: $PATH expands when /etc/profile.d/* is sourced
    echo 'export PATH="/usr/local/bin:$PATH"' > /etc/profile.d/pipx-path.sh
    log_ok "direnv configured"
  fi
}
