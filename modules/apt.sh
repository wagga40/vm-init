#!/usr/bin/env bash
# APT package installation module.
# Reads: CONFIG (path to vm-init.yml)

install_apt() {
  require_commands apt-get dpkg-query || return 1

  log_step "Collecting APT packages from config"
  local packages
  packages=$(yq -r '.apt.packages // {} | to_entries | .[].value | .[]' "$CONFIG" | sort -u)

  if [[ -z "$packages" ]]; then
    log_skip "No APT packages configured"
    return 0
  fi

  if should_upgrade || should_force; then
    log_step "Updating apt index"
    run_quiet apt_get update -q
    log_ok "apt index updated"
  fi

  # Availability guard. Everything below installs in a single apt-get call, so
  # one name absent from this release would fail the whole batch and leave
  # nothing installed. Partition against the freshly updated index instead, and
  # say plainly what got dropped.
  local available="" unavailable="" pkg
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    if apt_available "$pkg"; then
      available+="${pkg}"$'\n'
    else
      unavailable+="${pkg} "
    fi
  done <<< "$packages"

  if [[ -n "$unavailable" ]]; then
    log_warn "Not available on this Ubuntu release — skipped: ${unavailable% }"
  fi

  packages="${available%$'\n'}"
  if [[ -z "$packages" ]]; then
    log_warn "None of the configured APT packages are available on this release"
    return 0
  fi

  declare -A pre_versions=()
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    pre_versions[$pkg]=$(apt_installed_version "$pkg")
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

# Post-install verification: every configured package is actually installed.
# Names that this Ubuntu release does not carry are reported as skipped rather
# than missing, matching what install_apt would have done with them.
verify_apt() {
  require_commands dpkg-query apt-cache || return 1

  local packages pkg present=0
  local missing=() unavailable=()
  packages=$(yq -r '.apt.packages // {} | to_entries | .[].value | .[]' "$CONFIG" | sort -u)

  if [[ -z "$packages" ]]; then
    log_skip "No APT packages configured"
    return 0
  fi

  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$'; then
      present=$((present + 1))
    elif ! apt_available "$pkg"; then
      unavailable+=("$pkg")
    else
      missing+=("$pkg")
    fi
  done <<< "$packages"

  if (( ${#unavailable[@]} > 0 )); then
    log_skip "not available on this release: ${unavailable[*]}"
  fi

  if (( ${#missing[@]} > 0 )); then
    log_fail "${#missing[@]} configured package(s) not installed: ${missing[*]}"
    return 1
  fi

  log_ok "${present} configured package(s) installed"
}
