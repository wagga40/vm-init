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
  sshd_enabled=$(yq_get '.fail2ban.jails.sshd.enabled' false "$CONFIG")

  cat <<EOF

[sshd]
enabled = ${sshd_enabled}
EOF
}

install_fail2ban() {
  require_commands apt-get systemctl || return 1

  # Block service auto-start during install: the fail2ban unit is Type=notify
  # and its first start (against a fresh, empty config) can take many minutes
  # — long enough to hit our command timeout. We start it ourselves below,
  # after writing /etc/fail2ban/jail.d/vm-init.local.
  if ! is_installed fail2ban-client; then
    log_step "Installing fail2ban"
    run_quiet apt_get update -q
    if ! apt_no_service_start run_quiet apt_get install -y -q fail2ban; then
      log_fail "Failed to install fail2ban package"
      return 1
    fi
    log_ok "fail2ban installed"
  elif should_force; then
    log_step "Reinstalling fail2ban (--force)"
    apt_no_service_start run_quiet apt_get install -y -q --reinstall fail2ban
    log_ok "fail2ban reinstalled"
  else
    log_skip "fail2ban already installed"
  fi

  local temp destination="${VM_INIT_FAIL2BAN_ROOT:-}/etc/fail2ban/jail.d/vm-init.local" legacy=0 saved desired observed actual changed=false
  temp=$(mktemp) || return 1
  render_fail2ban_config > "$temp" || { rm -f "$temp"; return 1; }
  if reconcile_legacy fail2ban || [[ -f "$destination" ]]; then legacy=1; fi
  desired=$(fail2ban_spec "$temp" enabled)
  actual=$(systemctl is-enabled fail2ban 2>/dev/null) || { [[ -n "$actual" ]] || actual=absent; }
  observed=$(fail2ban_spec "$destination" "$actual")
  saved=$(reconcile_load fail2ban.configuration) || { rm -f "$temp"; return 1; }
  if systemctl is-active --quiet fail2ban && ! fail2ban_policy_matches "$temp"; then
    # A YAML change is safe when the running policy still matches the previous
    # generated file; runtime-only changes otherwise remain protected.
    if [[ "$saved" == null ]] || ! fail2ban_policy_matches "$destination"; then
      observed=$(jq -cS '.runtime="different"' <<< "$observed")
    fi
  fi
  reconcile_decide fail2ban.configuration "$desired" "$observed" "$legacy" || { rm -f "$temp"; return 1; }
  if [[ "$RECONCILE_ACTION" == drift ]]; then rm -f "$temp"; return 0; fi
  if [[ "$RECONCILE_ACTION" == apply ]]; then
    reconcile_begin fail2ban.configuration "$desired" "$observed" || { rm -f "$temp"; return 1; }
    if ! cmp -s "$temp" "$destination"; then
      mkdir -p "$(dirname "$destination")"
      if [[ -f "$destination" ]]; then cp -p "$destination" "$VM_INIT_STATE_DIR/baselines/fail2ban.${VM_INIT_RUN_ID:-backup}.bak"; fi
      local staged
      staged=$(mktemp "$(dirname "$destination")/.vm-init.XXXXXX") || { rm -f "$temp"; return 1; }
      cat "$temp" > "$staged"
      chmod 0644 "$staged"
      mv -f "$staged" "$destination"
    fi
    changed=true
    reconcile_checkpoint fail2ban.configuration "$(fail2ban_observe "$destination" "$actual")" || return 1
  fi
  rm -f "$temp"
  if [[ "$actual" != enabled ]]; then
    if [[ "$actual" == masked ]]; then systemctl unmask fail2ban || return 1; fi
    systemctl enable fail2ban || return 1
  fi
  if [[ "$changed" == true ]]; then
    reconcile_checkpoint fail2ban.configuration "$(fail2ban_observe "$destination" enabled)" || return 1
    run_quiet fail2ban-client -t || return 1
    if systemctl is-active --quiet fail2ban; then run_quiet fail2ban-client reload --restart || return 1
    else run_quiet systemctl start fail2ban || return 1; fi
  elif ! systemctl is-active --quiet fail2ban; then
    run_quiet systemctl start fail2ban || return 1
    reconcile_report fail2ban.runtime in_sync active active 'service started' true
  fi
  verify_fail2ban || return 1
  reconcile_accept fail2ban.configuration "$desired" "$desired" "$changed"
}

render_fail2ban_config() {
  local bantime findtime maxretry backend banaction_raw banaction ignoreip
  bantime=$(yq_get '.fail2ban.bantime' "1h" "$CONFIG")
  findtime=$(yq_get '.fail2ban.findtime' "10m" "$CONFIG")
  maxretry=$(yq_get '.fail2ban.maxretry' "5" "$CONFIG")
  backend=$(yq_get '.fail2ban.backend' "systemd" "$CONFIG")
  banaction_raw=$(yq_get '.fail2ban.banaction' "auto" "$CONFIG")
  banaction=$(fail2ban_resolve_banaction "$banaction_raw")
  ignoreip=$(yq -r '.fail2ban.ignoreip // ["127.0.0.1/8", "::1"] | join(" ")' "$CONFIG")

  {
    cat <<EOF
# Managed by vm-init — local changes are preserved unless restoration is requested.
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
  }

}

fail2ban_spec() {
  local content=absent
  if [[ -f "$1" ]]; then content=$(sed '/^[#;]/d; /^[[:space:]]*$/d' "$1" | _sha256_stdin) || return 1; fi
  jq -cnS --arg content "$content" --arg enabled "$2" '{content:$content,enabled:$enabled,runtime:"matching"}'
}

fail2ban_observe() {
  local spec
  spec=$(fail2ban_spec "$1" "$2") || return 1
  if systemctl is-active --quiet fail2ban && ! fail2ban_policy_matches "$1"; then
    jq -cS '.runtime="different"' <<< "$spec"
  else printf '%s\n' "$spec"; fi
}

fail2ban_policy_matches() {
  local file="$1" enabled option expected actual action
  [[ -f "$file" ]] || return 1
  enabled=$(sed -n 's/^enabled = //p' "$file")
  if [[ "$enabled" != true ]]; then
    ! fail2ban-client status sshd >/dev/null 2>&1
    return
  fi
  fail2ban-client status sshd >/dev/null 2>&1 || return 1
  for option in bantime findtime maxretry; do
    expected=$(sed -n "s/^${option} = //p" "$file") || return 1
    if [[ "$option" != maxretry && ! "$expected" =~ ^-?[0-9]+$ ]]; then
      expected=$(/usr/bin/python3 -c 'from fail2ban.server.mytime import MyTime; import sys; print(int(MyTime.str2seconds(sys.argv[1])))' "$expected") || return 1
    fi
    actual=$(fail2ban-client get sshd "$option") || return 1
    [[ "$actual" == "$expected" ]] || return 1
  done
  action=$(sed -n 's/^banaction = //p' "$file")
  fail2ban-client get sshd actions | grep -qxF "$action" || return 1
  expected=$(sed -n 's/^ignoreip = //p' "$file" | fail2ban_normalize_ips) || return 1
  actual=$(fail2ban-client get sshd ignoreip | sed -E 's/^[|`[:space:]-]+//' | sed '/^These IP addresses/d; /^No IP address/d; /^$/d' | fail2ban_normalize_ips) || return 1
  [[ "$actual" == "$expected" ]] || return 1
  expected=$(sed -n 's/^backend = //p' "$file")
  actual=$(fail2ban-client -d 2>/dev/null | python3 -c '
import ast, sys
for line in sys.stdin:
    try:
        command = ast.literal_eval(line)
    except (SyntaxError, ValueError):
        continue
    if isinstance(command, list) and command[:2] == ["add", "sshd"]:
        print(command[2]); break
else:
    sys.exit(1)
') || return 1
  [[ "$actual" == "$expected" ]] || return 1
  if [[ "$expected" == systemd ]]; then fail2ban-client get sshd journalmatch >/dev/null || return 1; fi
  return 0
}

fail2ban_normalize_ips() {
  python3 -c '
import ipaddress, sys
values = set()
for value in sys.stdin.read().split():
    try:
        value = str(ipaddress.ip_network(value, strict=False))
    except ValueError:
        pass
    values.add(value)
print("\n".join(sorted(values)))
'
}

inspect_fail2ban() (
  local temp legacy=0 enabled desired observed destination="${VM_INIT_FAIL2BAN_ROOT:-}/etc/fail2ban/jail.d/vm-init.local"
  temp=$(mktemp) || return 1
  trap 'rm -f "$temp"' EXIT
  render_fail2ban_config > "$temp" || return 1
  enabled=$(systemctl is-enabled fail2ban 2>/dev/null) || { [[ -n "$enabled" ]] || enabled=absent; }
  desired=$(fail2ban_spec "$temp" enabled)
  observed=$(fail2ban_spec "$destination" "$enabled")
  if systemctl is-active --quiet fail2ban && ! fail2ban_policy_matches "$destination"; then observed=$(jq -cS '.runtime="different"' <<< "$observed"); fi
  if reconcile_legacy fail2ban || [[ -f "$destination" ]]; then legacy=1; fi
  reconcile_decide fail2ban.configuration "$desired" "$observed" "$legacy"
)

# Post-install verification: the service is running and each jail we enabled in
# config is actually loaded by fail2ban.
verify_fail2ban() {
  require_commands systemctl || return 1
  local expected
  expected=$(mktemp) || return 1
  if ! render_fail2ban_config > "$expected" || ! fail2ban_policy_matches "$expected"; then
    rm -f "$expected"; log_fail 'Fail2ban effective policy differs from configuration'; return 1
  fi
  rm -f "$expected"

  if ! systemctl is-active --quiet fail2ban; then
    log_fail "fail2ban is not active"
    log_info "Debug: systemctl status fail2ban --no-pager"
    return 1
  fi
  log_ok "fail2ban active"

  if ! is_installed fail2ban-client; then
    log_warn "fail2ban-client not on PATH — jail status not checked"
    return 0
  fi

  local jails jail rc=0
  jails=$(yq -r '.fail2ban.jails // {} | to_entries | .[] | select(.value.enabled == true) | .key' \
    "$CONFIG" 2>/dev/null)

  if [[ -z "$jails" ]]; then
    log_skip "No jails enabled in config"
    return 0
  fi

  while IFS= read -r jail; do
    [[ -z "$jail" ]] && continue
    if fail2ban-client status "$jail" >/dev/null 2>&1; then
      log_ok "jail ${jail} loaded"
    else
      log_fail "jail ${jail} is enabled in config but not loaded"
      rc=1
    fi
  done <<< "$jails"

  return "$rc"
}
