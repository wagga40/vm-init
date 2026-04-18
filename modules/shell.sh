#!/usr/bin/env bash
# Fish shell configuration module.
# Reads: CONFIG (path to vm-init.yml)

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

  if [[ "$user" == "root" ]]; then
    run_quiet fish -c "$fish_cmd"
  else
    run_quiet sudo -u "$user" fish -c "$fish_cmd" || true
    chown -R "$user:$user" "${home_dir}/.config" 2>/dev/null || true
  fi
}

install_shell() {
  local default_shell
  default_shell=$(yq '.shell.default_shell // "fish"' "$CONFIG")

  local shell_path="/usr/bin/${default_shell}"
  if [[ ! -x "$shell_path" ]]; then
    log_warn "Shell ${default_shell} not found at ${shell_path} (skip)"
    return 1
  fi

  log_step "Setting ${default_shell} as default shell"
  usermod --shell "$shell_path" root
  while IFS=: read -r u _home; do
    chsh -s "$shell_path" "$u" 2>/dev/null || true
  done < <(human_users)

  local fisher_enabled
  fisher_enabled=$(yq_get '.shell.fisher' true "$CONFIG")
  if [[ "$fisher_enabled" == "true" ]]; then
    if should_force || ! fish -c 'fisher --version' >/dev/null 2>&1; then
      log_step "Installing Fisher + Tide (root)"
      install_fisher_tide "root" "/root"
      log_ok "Fisher + Tide (root)"

      while IFS=: read -r u home_dir; do
        log_step "Installing Fisher + Tide (${u})"
        chown -R "$u:$u" "${home_dir}/.config" 2>/dev/null || true
        install_fisher_tide "$u" "$home_dir"
        chown -R "$u:$u" "${home_dir}/.config" 2>/dev/null || true
        log_ok "Fisher + Tide (${u})"
      done < <(human_users)
    else
      log_skip "Fisher already installed"
    fi
  fi

  # Aliases
  log_step "Configuring aliases"
  local alias_keys
  alias_keys=$(yq '.shell.aliases | keys | .[]' "$CONFIG" 2>/dev/null)

  if [[ -n "$alias_keys" ]]; then
    local key value
    while IFS= read -r key; do
      value=$(yq ".shell.aliases.${key}" "$CONFIG")
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

  # Direnv
  local direnv_enabled
  direnv_enabled=$(yq_get '.shell.direnv' true "$CONFIG")
  if [[ "$direnv_enabled" == "true" ]]; then
    log_step "Configuring direnv and PATH"
    echo 'direnv hook fish | source' > /etc/fish/conf.d/direnv.fish
    echo 'fish_add_path -g /usr/local/bin' > /etc/fish/conf.d/pipx-path.fish
    # shellcheck disable=SC2016  # intentional: $PATH expands when /etc/profile.d/* is sourced
    echo 'export PATH="/usr/local/bin:$PATH"' > /etc/profile.d/pipx-path.sh
    log_ok "direnv configured"
  fi
}
