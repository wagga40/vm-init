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

install_act() {
  require_commands bash || return 1

  log_step "act"

  local pre=""
  if is_installed act; then
    pre=$(binary_version act 2>/dev/null || true)

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
  post=$(binary_version act 2>/dev/null || true)

  if [[ -z "$pre" ]]; then
    log_installed "act" "v${post:-unknown}"
  elif [[ -n "$post" && "$pre" != "$post" ]]; then
    log_upgraded "act" "v${pre}" "v${post}"
  else
    log_current "act" "v${pre}"
  fi
}

install_github_tools() {
  local gh_enabled act_enabled
  gh_enabled=$(yq_get '.github_tools.gh' true "$CONFIG")
  act_enabled=$(yq_get '.github_tools.act' true "$CONFIG")

  [[ "$gh_enabled" == "true" ]] && install_gh
  [[ "$act_enabled" == "true" ]] && install_act
}
