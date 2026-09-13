#!/usr/bin/env bash
# Offline DNS recovery, embedded in the single-file distribution as well.

dns_paths() {
  local suffix
  for suffix in /etc/resolv.conf /etc/systemd/system/dnsproxy.service \
    /etc/systemd/system/vm-init-dns-pin.service \
    /etc/systemd/system/systemd-resolved.service.d/10-vm-init-dnsproxy.conf \
    /etc/systemd/resolved.conf.d/99-vm-init-dnsproxy.conf \
    /etc/systemd/resolved.conf.d/00-recovery-dns.conf \
    /usr/local/sbin/vm-init-dns-pin /usr/local/bin/dnsproxy; do
    printf '%s%s\n' "${VM_INIT_DNS_ROOT:-}" "$suffix"
  done
}

dns_save_state() {
  local snapshot="$1" service paths=()
  mapfile -t paths < <(dns_paths)
  snapshot_paths "$snapshot" "${paths[@]}" || return 1
  : > "$snapshot/services"
  for service in dnsproxy vm-init-dns-pin systemd-resolved; do
    local enabled=0 active=0
    if systemctl is-enabled --quiet "$service" 2>/dev/null; then enabled=1; fi
    if systemctl is-active --quiet "$service" 2>/dev/null; then active=1; fi
    printf '%s %s %s\n' "$service" "$enabled" "$active" >> "$snapshot/services"
  done
  : > "$snapshot/links"
  local kind
  # A minimal image may not have resolved or resolvectl until this install.
  # An active resolver must be inspected successfully before it is changed.
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    require_commands resolvectl || return 1
    for kind in dns domain default-route; do
      resolvectl "$kind" 2>/dev/null | awk -v kind="$kind" '
        /^Link [0-9]+ \(/ {
          iface=$0; sub(/^.*\(/,"",iface); sub(/\):.*/,"",iface)
          value=$0; sub(/^.*\):[ ]*/,"",value)
          print kind " " iface " " value
        }' >> "$snapshot/links" || return 1
    done
  fi
}

dns_restore_state() {
  local snapshot="$1" service enabled active kind iface value rc=0 args=()
  systemctl stop dnsproxy vm-init-dns-pin >/dev/null 2>&1 || true
  restore_paths "$snapshot" || rc=1
  systemctl daemon-reload || rc=1
  while read -r service enabled active; do
    if [[ "$enabled" == 1 ]]; then
      systemctl enable "$service" >/dev/null 2>&1 || rc=1
    else
      systemctl disable "$service" >/dev/null 2>&1 || true
    fi
    if [[ "$active" == 1 ]]; then
      systemctl restart "$service" >/dev/null 2>&1 || rc=1
    else
      systemctl stop "$service" >/dev/null 2>&1 || true
    fi
  done < "$snapshot/services"
  while read -r kind iface value; do
    [[ -n "$iface" ]] || continue
    if [[ "$kind" == dns ]]; then resolvectl revert "$iface" >/dev/null 2>&1 || rc=1; fi
    [[ -n "$value" ]] || continue
    read -ra args <<< "$value"
    resolvectl "$kind" "$iface" "${args[@]}" >/dev/null 2>&1 || rc=1
  done < "$snapshot/links"
  return "$rc"
}

recover_dns_usage() {
  echo 'vm-init-recover-dns — offline DNS recovery'
  echo 'Usage: sudo vm-init repair dns [options]'
  echo 'Options:'
  echo '  --iface <name>       Revert a specific interface (default: all links)'
  echo '  --with-fallback      Use temporary public DNS if restoring state fails'
  echo '  --fallback "<list>"   Public resolver IPs (default: "1.1.1.1 9.9.9.9")'
  echo '  --help, -h           Show this help'
  echo 'Examples:'
  echo '  sudo vm-init repair dns --with-fallback'
}

recover_dns_main() {
  local iface="" fallback=0 servers='1.1.1.1 9.9.9.9' link root="${VM_INIT_DNS_ROOT:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --iface|--fallback)
        if [[ -z "${2:-}" || "$2" == -* ]]; then
          log_fail "Missing value for $1"; recover_dns_usage; return 1
        fi
        if [[ "$1" == --iface ]]; then iface="$2"; else servers="$2"; fi
        shift 2 ;;
      --with-fallback) fallback=1; shift ;;
      --help|-h) recover_dns_usage; return 0 ;;
      *) log_fail "Unknown option: $1"; recover_dns_usage; return 1 ;;
    esac
  done
  if [[ $EUID -ne 0 ]]; then log_fail 'Run as root: sudo vm-init repair dns'; return 1; fi
  require_commands systemctl getent || return 1
  acquire_run_lock || return 1
  if [[ -d "$VM_INIT_STATE_DIR/dns-original" ]]; then
    log_step 'Restoring the DNS configuration from before vm-init'
    if dns_restore_state "$VM_INIT_STATE_DIR/dns-original" && getent hosts example.com >/dev/null; then
      log_done 'DNS recovery complete.'
      log_info 'Set dns.enabled: false before applying this configuration again.'
      return 0
    fi
    if [[ "$fallback" != 1 ]]; then
      log_fail 'Restored DNS could not be verified. Retry with --with-fallback.'
      return 1
    fi
  fi
  require_commands resolvectl ip || return 1
  if [[ "$fallback" == 1 && ! "$servers" =~ ^[0-9a-fA-F:.\ ]+$ ]]; then
    log_fail 'Fallback DNS must contain IP addresses'; return 1
  fi
  log_step 'Removing vm-init DNS overrides'
  systemctl disable --now dnsproxy vm-init-dns-pin >/dev/null 2>&1 || true
  rm -f "$root/etc/systemd/system/dnsproxy.service" "$root/etc/systemd/system/vm-init-dns-pin.service" \
    "$root/etc/systemd/system/systemd-resolved.service.d/10-vm-init-dnsproxy.conf" \
    "$root/etc/systemd/resolved.conf.d/99-vm-init-dnsproxy.conf" "$root/usr/local/sbin/vm-init-dns-pin"
  if [[ -n "$iface" ]]; then
    resolvectl revert "$iface" || return 1
  else
    while read -r link; do
      [[ -n "$link" && "$link" != lo ]] || continue
      resolvectl revert "$link" || return 1
    done < <(ip -o link show | awk -F': ' '{ sub(/@.*/,"",$2); print $2 }')
  fi
  if [[ "$fallback" == 1 ]]; then
    # The values become resolver configuration, never shell commands.
    mkdir -p "$root/etc/systemd/resolved.conf.d"
    printf '[Resolve]\nDNS=%s\nFallbackDNS=\n' "$servers" > "$root/etc/systemd/resolved.conf.d/00-recovery-dns.conf"
  fi
  systemctl daemon-reload || return 1
  systemctl enable --now systemd-resolved || return 1
  systemctl restart systemd-resolved || return 1
  ln -sfn /run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf" || return 1
  if ! getent hosts example.com >/dev/null; then log_fail 'Name resolution is still failing'; return 1; fi
  log_done 'DNS recovery complete.'
  log_info 'Set dns.enabled: false before applying this configuration again.'
}
