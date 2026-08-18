#!/usr/bin/env bash
# GitHub CLI (gh) and act installation module.
# Reads: CONFIG (path to vm-init.yml)

install_gh() {
  require_commands apt-get dpkg || return 1

  if ! [[ -f /etc/apt/sources.list.d/github-cli.list ]]; then
    log_step "Setting up GitHub CLI apt repository"
    if ! download_file \
          "https://cli.github.com/packages/githubcli-archive-keyring.gpg" \
          /usr/share/keyrings/githubcli-archive-keyring.gpg; then
      log_fail "Failed to download GitHub CLI keyring"
      return 1
    fi
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
https://cli.github.com/packages stable main" \
      | tee /etc/apt/sources.list.d/github-cli.list > /dev/null

    run_quiet apt_get update -q
  fi

  apt_install_with_report gh
}

# `act --version` prints "act version 0.2.68". Narrow and module-local on
# purpose: _common.sh dropped its generic probe because TUI binaries launch
# their UI instead of printing a version (see the NOTE there). act is a plain
# CLI, so probing it is safe.
_act_version() {
  act --version 2>/dev/null | awk 'NR == 1 { print $NF }'
}

install_act() {
  require_commands bash awk || return 1

  log_step "act"

  local pre=""
  if is_installed act; then
    pre=$(_act_version || true)

    if ! should_force && ! should_upgrade; then
      log_current "act" "v${pre:-unknown}"
      return 0
    fi
  fi

  # act ships a remote installer script; download to a tempfile (with retries)
  # so we can log it and not pipe an opaque remote payload straight to bash.
  local act_install
  act_install=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f -- '${act_install}'" RETURN

  if ! download_file \
        "https://raw.githubusercontent.com/nektos/act/master/install.sh" \
        "$act_install"; then
    log_fail "Failed to download act installer"
    return 1
  fi

  log_info "act installer sha256: $(_sha256_of "$act_install" 2>/dev/null || echo '<unavailable>')"

  if ! run_quiet bash "$act_install" -d -b /usr/local/bin; then
    log_fail "act installer exited non-zero"
    return 1
  fi

  local post
  post=$(_act_version || true)

  if [[ -z "$pre" ]]; then
    log_installed "act" "v${post:-unknown}"
  elif [[ -n "$post" && "$pre" != "$post" ]]; then
    log_upgraded "act" "v${pre}" "v${post}"
  else
    log_current "act" "v${pre}"
  fi
}

install_github_tools() {
  local gh_enabled act_enabled rc=0
  gh_enabled=$(yq_get '.github_tools.gh' true "$CONFIG")
  act_enabled=$(yq_get '.github_tools.act' true "$CONFIG")

  # Explicit ifs, not `[[ ... ]] && install_x`: as the last statement of the
  # function that idiom returns the *test's* status, so a disabled tool made the
  # module report failure even when the enabled one installed cleanly.
  if [[ "$gh_enabled" == "true" ]]; then
    install_gh || rc=1
  fi
  if [[ "$act_enabled" == "true" ]]; then
    install_act || rc=1
  fi

  return "$rc"
}

verify_github_tools() {
  local gh_enabled act_enabled rc=0
  gh_enabled=$(yq_get '.github_tools.gh' true "$CONFIG")
  act_enabled=$(yq_get '.github_tools.act' true "$CONFIG")

  if [[ "$gh_enabled" == "true" ]]; then
    if is_installed gh && gh --version >/dev/null 2>&1; then
      log_ok "gh $(gh --version 2>/dev/null | awk 'NR == 1 { print $3 }')"
    else
      log_fail "gh is enabled but not installed"
      rc=1
    fi
  fi

  if [[ "$act_enabled" == "true" ]]; then
    local ver
    ver=$(_act_version || true)
    if [[ -n "$ver" ]]; then
      log_ok "act ${ver}"
    else
      log_fail "act is enabled but not installed"
      rc=1
    fi
  fi

  if [[ "$gh_enabled" != "true" && "$act_enabled" != "true" ]]; then
    log_skip "No GitHub tools enabled"
  fi

  return "$rc"
}
