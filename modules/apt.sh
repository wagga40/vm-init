#!/usr/bin/env bash
# APT package installation module.
# Reads: CONFIG (path to vm-init.yml)

install_apt() {
  require_commands apt-get dpkg-query || return 1

  log_step "Collecting APT packages from config"
  local packages
  packages=$(yq '.apt.packages | to_entries | .[].value | .[]' "$CONFIG" | sort -u)

  if [[ -z "$packages" ]]; then
    log_skip "No APT packages configured"
    return 0
  fi

  log_step "Updating apt index"
  run_quiet apt_get update -q
  log_ok "apt index updated"

  declare -A pre_versions=()
  local pkg
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    pre_versions[$pkg]=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)
  done <<< "$packages"

  if should_force; then
    log_step "Reinstalling APT packages"
    # shellcheck disable=SC2086
    run_quiet apt_get install -y -q --reinstall $packages
  elif should_upgrade; then
    log_step "Installing/upgrading APT packages"
    # shellcheck disable=SC2086
    run_quiet apt_get install -y -q $packages
  else
    local missing=""
    while IFS= read -r pkg; do
      [[ -z "$pkg" ]] && continue
      [[ -z "${pre_versions[$pkg]}" ]] && missing+=" $pkg"
    done <<< "$packages"
    if [[ -n "$missing" ]]; then
      log_step "Installing missing APT packages"
      # shellcheck disable=SC2086
      run_quiet apt_get install -y -q $missing
    fi
  fi

  local installed_n=0 upgraded_n=0 current_n=0
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    local pre="${pre_versions[$pkg]}" post
    post=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)
    if [[ -z "$pre" && -n "$post" ]]; then
      installed_n=$((installed_n + 1))
      _tally installed
    elif [[ -n "$pre" && -n "$post" && "$pre" != "$post" ]]; then
      upgraded_n=$((upgraded_n + 1))
      _tally upgraded
    elif [[ -n "$pre" ]]; then
      current_n=$((current_n + 1))
      _tally current
    fi
  done <<< "$packages"

  log_info "APT: ${installed_n} installed, ${upgraded_n} upgraded, ${current_n} current"
}
