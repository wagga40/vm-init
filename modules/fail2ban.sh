#!/usr/bin/env bash
# Fail2ban brute-force protection module.
# Reads: CONFIG (path to vm-init.yml)
#
# Installs fail2ban from APT and writes a managed jail.d/vm-init.local
# override so our defaults layer cleanly on top of distro defaults. The
# ban action defaults to "auto", resolving to "ufw" when UFW is present
# and "iptables-multiport" otherwise.

# Resolve fail2ban.banaction: "auto" -> ufw if installed, else iptables-multiport.
fail2ban_resolve_banaction() {
  local raw="$1"
  if [[ -z "$raw" || "$raw" == "auto" ]]; then
    if is_installed ufw; then
      echo "ufw"
    else
      echo "iptables-multiport"
    fi
    return 0
  fi
  echo "$raw"
}

# Render [jail] stanzas for every entry under .fail2ban.jails.
# Currently supports: sshd (enabled/disabled).
fail2ban_render_jail_blocks() {
  local sshd_enabled
  sshd_enabled=$(yq_get '.fail2ban.jails.sshd.enabled' true "$CONFIG")

  cat <<EOF

[sshd]
enabled = ${sshd_enabled}
EOF
}

install_fail2ban() {
  if ! is_installed fail2ban-client; then
    log_step "Installing fail2ban"
    export DEBIAN_FRONTEND=noninteractive
    run_quiet apt-get update -qq
    if ! run_quiet apt-get install -y -qq fail2ban; then
      log_fail "Failed to install fail2ban package"
      return 1
    fi
    log_ok "fail2ban installed"
  elif should_force; then
    log_step "Reinstalling fail2ban (--force)"
    export DEBIAN_FRONTEND=noninteractive
    run_quiet apt-get install -y -qq --reinstall fail2ban
    log_ok "fail2ban reinstalled"
  else
    log_skip "fail2ban already installed"
  fi

  local bantime findtime maxretry backend banaction_raw banaction ignoreip
  bantime=$(yq_get '.fail2ban.bantime' "1h" "$CONFIG")
  findtime=$(yq_get '.fail2ban.findtime' "10m" "$CONFIG")
  maxretry=$(yq_get '.fail2ban.maxretry' "5" "$CONFIG")
  backend=$(yq_get '.fail2ban.backend' "systemd" "$CONFIG")
  banaction_raw=$(yq_get '.fail2ban.banaction' "auto" "$CONFIG")
  banaction=$(fail2ban_resolve_banaction "$banaction_raw")
  ignoreip=$(yq '.fail2ban.ignoreip // ["127.0.0.1/8", "::1"] | join(" ")' "$CONFIG")

  log_step "Writing fail2ban jail overrides"
  mkdir -p /etc/fail2ban/jail.d
  {
    cat <<EOF
# Managed by vm-init — edits here will be overwritten on next run.
# Remove this file (or set fail2ban.enabled: false) to opt out.
[DEFAULT]
bantime = ${bantime}
findtime = ${findtime}
maxretry = ${maxretry}
backend = ${backend}
banaction = ${banaction}
banaction_allports = ${banaction}
ignoreip = ${ignoreip}
EOF
    fail2ban_render_jail_blocks
  } > /etc/fail2ban/jail.d/vm-init.local

  log_step "Enabling and restarting fail2ban"
  systemctl enable fail2ban >/dev/null 2>&1 || true
  if ! systemctl restart fail2ban >/dev/null 2>&1; then
    log_warn "fail2ban failed to restart"
    log_info "Debug: journalctl -u fail2ban -n 30 --no-pager"
    log_info "Debug: fail2ban-client -d   # dump effective config"
    return 0
  fi

  if systemctl is-active --quiet fail2ban; then
    log_ok "fail2ban active (banaction=${banaction}, bantime=${bantime}, maxretry=${maxretry})"
  else
    log_warn "fail2ban is not active after restart"
    log_info "Debug: systemctl status fail2ban --no-pager"
  fi
}
