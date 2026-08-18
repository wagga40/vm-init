#!/usr/bin/env bash
# UFW firewall baseline module.
# Reads: CONFIG (path to vm-init.yml)

install_ufw() {
  require_commands apt-get sed || return 1

  if ! is_installed ufw; then
    log_step "Installing ufw"
    run_quiet apt_get update -q
    run_quiet apt_get install -y -q ufw
    log_ok "ufw installed"
  fi

  local ipv6_enabled
  ipv6_enabled=$(yq_get '.ufw.ipv6' true "$CONFIG")
  local ipv6_value="yes"
  [[ "$ipv6_enabled" == "true" ]] || ipv6_value="no"
  if [[ -f /etc/default/ufw ]]; then
    run_quiet sed -i "s/^IPV6=.*/IPV6=${ipv6_value}/" /etc/default/ufw
  fi

  local incoming outgoing
  incoming=$(yq '.ufw.defaults.incoming // "deny"' "$CONFIG")
  outgoing=$(yq '.ufw.defaults.outgoing // "allow"' "$CONFIG")

  log_step "Configuring ufw defaults"
  run_quiet ufw default "$incoming" incoming
  run_quiet ufw default "$outgoing" outgoing

  log_step "Applying ufw allow rules"
  local rules
  rules=$(yq '.ufw.allow[]? // ""' "$CONFIG")
  if [[ -n "$rules" ]]; then
    local rule
    while IFS= read -r rule; do
      [[ -z "$rule" ]] && continue
      run_quiet ufw allow "$rule"
    done <<< "$rules"
  fi

  log_step "Enabling ufw"
  run_quiet ufw --force enable
  log_ok "ufw configured (incoming: ${incoming}, outgoing: ${outgoing})"
}

# Post-install verification: the firewall is actually up and every configured
# allow rule is present in the live ruleset.
verify_ufw() {
  require_commands ufw || return 1

  local status rules rule missing=()
  if ! status=$(ufw status 2>/dev/null); then
    log_fail "ufw status failed (needs root)"
    return 1
  fi

  if ! grep -qi '^Status: active' <<< "$status"; then
    log_fail "ufw is installed but not active"
    return 1
  fi
  log_ok "ufw active"

  rules=$(yq '.ufw.allow[]? // ""' "$CONFIG")
  while IFS= read -r rule; do
    [[ -z "$rule" ]] && continue
    # `ufw status` lists a service rule by its name (OpenSSH) and a port rule by
    # its number, so a substring match is the right granularity here.
    grep -qF "$rule" <<< "$status" || missing+=("$rule")
  done <<< "$rules"

  if (( ${#missing[@]} > 0 )); then
    log_fail "allow rule(s) not in the live ruleset: ${missing[*]}"
    return 1
  fi
  log_ok "all configured allow rules present"
}
