#!/usr/bin/env bash
# GitHub CLI (gh) and act installation module.
# Reads: CONFIG (path to vm-init.yml)

install_gh() {
  require_commands apt-get dpkg || return 1

  if is_installed gh && ! should_force; then
    log_skip "gh already installed"
    return 0
  fi

  log_step "Installing GitHub CLI (gh)"
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

  run_quiet apt-get update -qq
  run_quiet apt-get install -y -qq gh
  log_ok "gh installed"
}

install_act() {
  require_commands bash || return 1

  if is_installed act && ! should_force; then
    log_skip "act already installed"
    return 0
  fi

  log_step "Installing act"
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
  log_ok "act installed"
}

install_github_tools() {
  local gh_enabled act_enabled
  gh_enabled=$(yq_get '.github_tools.gh' true "$CONFIG")
  act_enabled=$(yq_get '.github_tools.act' true "$CONFIG")

  [[ "$gh_enabled" == "true" ]] && install_gh
  [[ "$act_enabled" == "true" ]] && install_act
}
