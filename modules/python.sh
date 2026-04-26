#!/usr/bin/env bash
# Python tooling via pipx module.
# Reads: CONFIG (path to vm-init.yml)

install_python() {
  require_commands pipx || return 1

  log_step "Setting up pipx environment"
  mkdir -p /opt/pipx
  export PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin

  local tools
  tools=$(yq '.python.tools[]' "$CONFIG")

  if [[ -z "$tools" ]]; then
    log_skip "No Python tools configured"
    return 0
  fi

  local tool
  while IFS= read -r tool; do
    if should_force; then
      log_step "Reinstalling ${tool}"
      run_quiet bash -c "pipx reinstall '${tool}' 2>/dev/null || pipx install '${tool}'"
    else
      log_step "Installing/upgrading ${tool}"
      run_quiet bash -c "pipx upgrade '${tool}' 2>/dev/null || pipx install '${tool}'"
    fi
    log_ok "${tool}"
  done <<< "$tools"
}
