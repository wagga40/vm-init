#!/usr/bin/env bash
# APT package installation module.
# Reads: CONFIG (path to vm-init.yml)

install_apt() {
  require_commands apt-get || return 1

  log_step "Collecting APT packages from config"
  local packages
  packages=$(yq '.apt.packages | to_entries | .[].value | .[]' "$CONFIG" | sort -u)

  if [[ -z "$packages" ]]; then
    log_skip "No APT packages configured"
    return 0
  fi

  log_step "Updating apt index"
  export DEBIAN_FRONTEND=noninteractive
  run_quiet apt-get update -qq
  log_ok "apt index updated"

  log_step "Installing APT packages"
  # shellcheck disable=SC2086
  run_quiet apt-get install -y -qq $packages
  log_ok "APT packages installed"
}
