#!/usr/bin/env bash
# UFW firewall baseline module.
# Reads: CONFIG (path to vm-init.yml)

install_ufw() {
  if ! is_installed ufw; then
    log_step "Installing ufw"
    run_quiet apt-get update -qq
    run_quiet apt-get install -y -qq ufw
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
