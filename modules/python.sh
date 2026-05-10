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

  declare -A pre_versions=()
  local pipx_pre tool ver
  pipx_pre=$(pipx list --short 2>/dev/null || true)
  while IFS=' ' read -r tool ver _; do
    [[ -n "$tool" ]] && pre_versions[$tool]="$ver"
  done <<< "$pipx_pre"

  while IFS= read -r tool; do
    [[ -z "$tool" ]] && continue
    if should_force; then
      log_step "Reinstalling ${tool}"
      run_quiet bash -c "pipx reinstall '${tool}' 2>/dev/null || pipx install '${tool}'"
    elif should_upgrade; then
      log_step "Installing/upgrading ${tool}"
      run_quiet bash -c "pipx upgrade '${tool}' 2>/dev/null || pipx install '${tool}'"
    else
      if [[ -z "${pre_versions[$tool]:-}" ]]; then
        log_step "Installing ${tool}"
        run_quiet pipx install "$tool"
      fi
    fi
  done <<< "$tools"

  declare -A post_versions=()
  local pipx_post
  pipx_post=$(pipx list --short 2>/dev/null || true)
  while IFS=' ' read -r tool ver _; do
    [[ -n "$tool" ]] && post_versions[$tool]="$ver"
  done <<< "$pipx_post"

  while IFS= read -r tool; do
    [[ -z "$tool" ]] && continue
    local pre="${pre_versions[$tool]:-}" post="${post_versions[$tool]:-}"
    if [[ -z "$pre" && -n "$post" ]]; then
      log_installed "$tool" "v${post}"
    elif [[ -n "$pre" && -n "$post" && "$pre" != "$post" ]]; then
      log_upgraded "$tool" "v${pre}" "v${post}"
    elif [[ -n "$pre" ]]; then
      log_current "$tool" "v${pre}"
    fi
  done <<< "$tools"
}
