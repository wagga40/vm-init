#!/usr/bin/env bash
# DNS privacy client module using dnsproxy (DoH/DoT).
# Reads: CONFIG (path to vm-init.yml)
# shellcheck disable=SC2030,SC2031 # inspectors and installers each prepare their own stage

install_dnsproxy_binary() {
  local sys_arch arch_pattern
  sys_arch=$(dpkg --print-architecture)
  case "$sys_arch" in
    amd64) arch_pattern='linux-amd64' ;;
    arm64) arch_pattern='linux-(arm64|aarch64)' ;;
    *)
      log_warn "dnsproxy: unsupported architecture ${sys_arch} (skip)"
      return 1
      ;;
  esac

  if is_installed dnsproxy && ! should_force; then
    log_skip "dnsproxy already installed"
    return 0
  fi

  log_step "Installing dnsproxy"

  local auth_args=() release_json asset_url
  mapfile -t auth_args < <(_github_auth_args)
  if ! release_json=$(curl_retry \
        "${auth_args[@]}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/AdguardTeam/dnsproxy/releases/latest"); then
    log_fail "Failed to fetch dnsproxy release metadata"
    return 1
  fi
  asset_url=$(echo "$release_json" \
    | jq -r ".assets[] | select(.name | test(\"${arch_pattern}.*\\\\.tar\\\\.gz$\"; \"i\")) | .browser_download_url" \
    | head -1)

  if [[ -z "${asset_url}" || "${asset_url}" == "null" ]]; then
    log_fail "dnsproxy release asset not found for ${sys_arch}"
    return 1
  fi

  local tmp
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064  # $tmp must expand now so cleanup knows the path
  trap "rm -rf -- '${tmp}'" RETURN

  if ! download_file "$asset_url" "$tmp/dnsproxy.tar.gz"; then
    log_fail "Failed to download ${asset_url}"
    return 1
  fi

  # Best-effort checksum verification against sidecar sha256.
  if ! try_verify_github_asset "$tmp/dnsproxy.tar.gz" "${asset_url}.sha256"; then
    log_fail "Checksum failed for dnsproxy tarball"
    return 1
  fi

  if ! run_quiet tar xzf "$tmp/dnsproxy.tar.gz" -C "$tmp"; then
    log_fail "Failed to extract dnsproxy tarball"
    return 1
  fi

  local dnsproxy_bin
  dnsproxy_bin=$(find "$tmp" -maxdepth 3 -type f -name dnsproxy -perm -u+x | head -1)
  if [[ -z "$dnsproxy_bin" ]]; then
    log_fail "dnsproxy binary not found inside tarball"
    return 1
  fi
  install -m 0755 "$dnsproxy_bin" /usr/local/bin/dnsproxy
  log_ok "dnsproxy installed"
}

dns_upstream_from_config() {
  local server
  server=$(yq -r '.dns.server // "https://base.dns.mullvad.net/dns-query"' "$CONFIG")

  if [[ "$server" != https://* && "$server" != tls://* ]]; then
    log_fail "dns.server must be a full URL starting with https:// (DoH) or tls:// (DoT)"
    return 1
  fi

  echo "$server"
}

ensure_systemd_resolved() {
  if ! systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1 \
      || ! systemctl cat systemd-resolved.service >/dev/null 2>&1; then
    log_step "Installing systemd-resolved"
    if ! run_quiet apt_get install -y -q systemd-resolved; then
      log_fail "Failed to install systemd-resolved package"
      return 1
    fi
  fi

  if ! systemctl is-enabled --quiet systemd-resolved 2>/dev/null; then
    if systemctl is-enabled systemd-resolved 2>/dev/null | grep -qx masked; then
      systemctl unmask systemd-resolved || return 1
    fi
    systemctl enable systemd-resolved >/dev/null 2>&1 || true
  fi
  if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    systemctl start systemd-resolved >/dev/null 2>&1 || true
  fi

  if ! systemctl is-active --quiet systemd-resolved; then
    log_fail "systemd-resolved is not active; cannot configure DoH"
    return 1
  fi
}

install_dns_pin_helper() {
  cat > "${VM_INIT_DNS_ROOT:-}/usr/local/sbin/vm-init-dns-pin" <<'PIN_EOF' || return 1
#!/bin/sh
# vm-init-dns-pin -- Pin default-route links to the local dnsproxy.
# Installed by modules/dns.sh and run once on every boot via
# vm-init-dns-pin.service so that DHCP-supplied per-link DNS settings can't
# bypass the global "DNS=127.0.0.1:5353 / Domains=~." config in
# systemd-resolved. Idempotent; safe to run by hand.
#
# Usage: vm-init-dns-pin [<addr[:port]>]
#   default target: ${VM_INIT_DNS_TARGET:-127.0.0.1:5353}
set -e
TARGET="${1:-${VM_INIT_DNS_TARGET:-127.0.0.1:5353}}"
command -v resolvectl >/dev/null 2>&1 || exit 0
links=$( { ip -4 route show default 2>/dev/null | awk '/^default /{print $5}'
           ip -6 route show default 2>/dev/null | awk '/^default /{print $5}'; } \
         | sort -u )
[ -z "$links" ] && exit 0
for iface in $links; do
  resolvectl dns "$iface" "$TARGET" >/dev/null 2>&1 || true
  resolvectl domain "$iface" '~.' >/dev/null 2>&1 || true
done
PIN_EOF
  chmod 0755 "${VM_INIT_DNS_ROOT:-}/usr/local/sbin/vm-init-dns-pin" || return 1
}

dnsproxy_listening_on() {
  local addr="$1" port="$2"
  if command -v ss >/dev/null 2>&1; then
    # Match address:port (dnsproxy binds to $addr) or 0.0.0.0:port (wildcard bind)
    ss -lunH "sport = :${port}" 2>/dev/null \
      | awk -v addr="$addr" -v port="$port" '
        {
          for (i = 1; i <= NF; i++) {
            if ($i == addr ":" port || $i == "[" addr "]:" port || $i == "0.0.0.0:" port || $i == "*:" port) {
              found = 1
              exit
            }
          }
        }
        END { exit found ? 0 : 1 }
      '
  else
    return 1
  fi
}

wait_for_dnsproxy() {
  local addr="$1" port="$2"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if systemctl is-active --quiet dnsproxy \
        && dnsproxy_listening_on "$addr" "$port"; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

verify_doh_resolves() {
  for _ in 1 2 3 4 5; do
    if dig +time=2 +tries=1 +short @"${1:-127.0.0.1}" -p "${2:-5353}" example.com A 2>/dev/null | grep -qE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$"; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

render_dns_config() {
  mkdir -p "${VM_INIT_DNS_ROOT:-}/etc/systemd/system" "${VM_INIT_DNS_ROOT:-}/usr/local/sbin" || return 1
  local upstream listen_address listen_port
  if ! upstream=$(dns_upstream_from_config); then
    log_warn "DNS module skipped — invalid dns.server in config"
    return 1
  fi
  listen_address=$(yq -r '.dns.listen_address // "127.0.0.1"' "$CONFIG")
  listen_port=$(yq -r '.dns.listen_port // 5353' "$CONFIG")

  # systemd-resolved DNS= syntax: "address:port" (colon for port, hash is SNI).
  local resolved_dns_target
  resolved_dns_target=$(dns_target "$listen_address" "$listen_port")

  local bootstrap_flags=""
  local bs_line
  while IFS= read -r bs_line; do
    [[ -z "$bs_line" ]] && continue
    bootstrap_flags+=" --bootstrap ${bs_line}"
  done <<< "$(yq -r '.dns.bootstrap // ["9.9.9.9", "149.112.112.112"] | .[]' "$CONFIG")"

  log_step "Writing dnsproxy service"
  # Ordering rationale (this is the bit that breaks DNS on reboot if wrong):
  #  - After=network.target              loopback + basic network are up
  #  - Before=systemd-resolved.service   so resolved sees a working :5353 from
  #                                      its very first query at boot. Paired
  #                                      with the resolved drop-in below
  #                                      (Wants/After=dnsproxy.service) which
  #                                      pulls dnsproxy into resolved's boot
  #                                      transaction so this Before= actually
  #                                      takes effect.
  #  - Before=nss-lookup.target          dnsproxy is a DNS provider; it must
  #                                      be ready before nss-lookup is reached
  #                                      (After=nss-lookup.target would be a
  #                                      classic mistake here).
  #  - Type=exec + ExecStartPost wait    `systemctl restart dnsproxy` only
  #                                      returns once the UDP socket is bound,
  #                                      so resolved's restart truly races
  #                                      against a ready proxy.
  #  - No network-online.target          dnsproxy uses --bootstrap so it does
  #                                      not need DNS, and network-online is
  #                                      reached very late at boot which is
  #                                      what made resolved fall back to a
  #                                      dead :5353 the first time around.
  cat > "${VM_INIT_DNS_ROOT:-}/etc/systemd/system/dnsproxy.service" <<EOF || return 1
[Unit]
Description=DNS over HTTPS/TLS proxy (dnsproxy)
Documentation=https://github.com/AdguardTeam/dnsproxy
After=network.target
Before=systemd-resolved.service nss-lookup.target
Wants=nss-lookup.target

[Service]
Type=exec
ExecStart=/usr/local/bin/dnsproxy --upstream=${upstream} --listen=${listen_address} --port=${listen_port}${bootstrap_flags} --cache --upstream-mode=parallel
ExecStartPost=/bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do ss -lunH "sport = :${listen_port}" 2>/dev/null | grep -q . && exit 0; sleep 0.2; done; exit 1'
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  rm -f "${VM_INIT_DNS_ROOT:-}/etc/systemd/resolved.conf.d/00-recovery-dns.conf" || return 1
  log_step "Pointing systemd-resolved to dnsproxy"
  mkdir -p "${VM_INIT_DNS_ROOT:-}/etc/systemd/resolved.conf.d" || return 1
  cat > "${VM_INIT_DNS_ROOT:-}/etc/systemd/resolved.conf.d/99-vm-init-dnsproxy.conf" <<EOF || return 1
[Resolve]
DNS=
DNS=${resolved_dns_target}
FallbackDNS=
Domains=~.
DNSStubListener=yes
EOF

  log_step "Making systemd-resolved wait for dnsproxy at boot"
  # Without this drop-in the Before= in dnsproxy.service is a no-op at boot:
  # systemd-resolved is activated very early, in a different transaction, so
  # there is no shared activation for the ordering to apply to. Pulling
  # dnsproxy in via Wants= here puts both units in the same transaction.
  mkdir -p "${VM_INIT_DNS_ROOT:-}/etc/systemd/system/systemd-resolved.service.d" || return 1
  cat > "${VM_INIT_DNS_ROOT:-}/etc/systemd/system/systemd-resolved.service.d/10-vm-init-dnsproxy.conf" <<EOF || return 1
[Unit]
Wants=dnsproxy.service
After=dnsproxy.service
EOF

  log_step "Installing per-link DNS pin helper"
  install_dns_pin_helper || return 1
  cat > "${VM_INIT_DNS_ROOT:-}/etc/systemd/system/vm-init-dns-pin.service" <<EOF || return 1
[Unit]
Description=Pin per-link DNS to local dnsproxy (vm-init)
Documentation=https://github.com/wagga40/vm-init
After=network-online.target dnsproxy.service systemd-resolved.service
Wants=network-online.target dnsproxy.service systemd-resolved.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vm-init-dns-pin ${resolved_dns_target}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  log_step "Ensuring resolv.conf uses the stub resolver"
  ln -sfn /run/systemd/resolve/stub-resolv.conf "${VM_INIT_DNS_ROOT:-}/etc/resolv.conf" || return 1

  return 0
}

_configure_dns() {
  local suffix source destination changed_units=0 changed_proxy=0 changed_resolved=0 changed_pin=0
  local listen_address listen_port resolved_dns_target
  if should_force; then changed_proxy=1; fi
  if [[ "$(jq -r '.effective' <<< "$DNS_OBSERVED")" == false ]]; then
    # The managed files can already match while systemd still has an older
    # unit loaded or resolved has different runtime routing. This path is only
    # reached after reconciliation has authorized the configuration change.
    changed_units=1; changed_proxy=1; changed_resolved=1; changed_pin=1
  fi
  listen_address=$(yq_get '.dns.listen_address' 127.0.0.1 "$CONFIG")
  listen_port=$(yq_get '.dns.listen_port' 5353 "$CONFIG")
  resolved_dns_target=$(dns_target "$listen_address" "$listen_port")
  while read -r suffix; do
    source="$DNS_STAGE$suffix"
    destination="${VM_INIT_DNS_ROOT:-}$suffix"
    if [[ "$(reconcile_file_value "$source")" == "$(reconcile_file_value "$destination")" ]]; then continue; fi
    case "$suffix" in
      */dnsproxy.service) changed_units=1; changed_proxy=1 ;;
      */vm-init-dns-pin.service|*/vm-init-dns-pin) changed_units=1; changed_pin=1 ;;
      */systemd-resolved.service.d/*) changed_units=1; changed_resolved=1 ;;
      *) changed_resolved=1 ;;
    esac
    mkdir -p "$(dirname "$destination")"
    if [[ -L "$source" ]]; then ln -sfn "$(readlink "$source")" "$destination"
    else
      local temp
      temp=$(mktemp "$(dirname "$destination")/.vm-init.XXXXXX") || return 1
      cat "$source" > "$temp"
      if [[ "$suffix" == /usr/local/sbin/* ]]; then chmod 0755 "$temp"; else chmod 0644 "$temp"; fi
      mv -f "$temp" "$destination"
    fi
  done < <(dns_config_paths)
  if [[ -e "${VM_INIT_DNS_ROOT:-}/etc/systemd/resolved.conf.d/00-recovery-dns.conf" ]]; then
    rm -f "${VM_INIT_DNS_ROOT:-}/etc/systemd/resolved.conf.d/00-recovery-dns.conf"
    changed_resolved=1
  fi
  if (( changed_units )) && ! systemctl daemon-reload >/dev/null 2>&1; then
    log_warn "systemd daemon-reload failed after writing DNS units"
    return 1
  fi
  local service
  for service in dnsproxy vm-init-dns-pin; do
    if ! systemctl is-enabled --quiet "$service"; then
      if systemctl is-enabled "$service" 2>/dev/null | grep -qx masked; then systemctl unmask "$service" || return 1; fi
      systemctl enable "$service" || return 1
    fi
  done
  if { (( changed_proxy )) || ! systemctl is-active --quiet dnsproxy; } && ! systemctl restart dnsproxy >/dev/null 2>&1; then
    log_warn "dnsproxy failed to start"
    log_info "Debug: journalctl -u dnsproxy -n 30 --no-pager"
    return 1
  fi

  if ! wait_for_dnsproxy "$listen_address" "$listen_port"; then
    log_warn "dnsproxy is not listening on ${listen_address}:${listen_port} after 5s"
    log_info "Debug: systemctl status dnsproxy --no-pager"
    log_info "Debug: journalctl -u dnsproxy -n 30 --no-pager"
    log_info "Debug: ss -lunp | grep ${listen_port}"
    log_info "Recovery: sudo vm-init repair dns --with-fallback"
    return 1
  fi

  if (( changed_resolved )) && ! systemctl restart systemd-resolved >/dev/null 2>&1; then
    log_warn "systemd-resolved failed to restart"
    log_info "Debug: systemctl status systemd-resolved --no-pager"
    return 1
  fi
  # Apply the boot-time pinning right now too (and surface failures via the
  # oneshot's exit status); fall back to invoking the helper directly.
  if { (( changed_pin || changed_resolved || changed_proxy )) || [[ "$DNS_OBSERVED" != "$DNS_DESIRED" ]]; } \
      && ! systemctl restart vm-init-dns-pin >/dev/null 2>&1 \
      && ! /usr/local/sbin/vm-init-dns-pin "$resolved_dns_target" >/dev/null 2>&1; then
    log_warn "Failed to apply per-link DNS pinning"
    log_info "Debug: systemctl status vm-init-dns-pin --no-pager"
    return 1
  fi

  if verify_doh_resolves "$listen_address" "$listen_port"; then
    log_ok "Direct query to the local DNS proxy succeeds"
  else
    log_warn "dnsproxy is listening but DNS resolution failed"
    log_info "Debug: resolvectl status"
    log_info "Debug: resolvectl query example.com"
    log_info "Debug: journalctl -u dnsproxy -n 30 --no-pager"
    log_info "Recovery: sudo vm-init repair dns --with-fallback"
    return 1
  fi
}

# Post-install verification. Reuses the helpers install_dns already relies on,
# so the check and the install agree on what "working" means.
verify_dns() {
  require_commands systemctl getent ss dig resolvectl || return 1

  local listen_address listen_port upstream rc=0
  listen_address=$(yq -r '.dns.listen_address // "127.0.0.1"' "$CONFIG")
  listen_port=$(yq -r '.dns.listen_port // 5353' "$CONFIG")
  upstream=$(dns_upstream_from_config)

  if ! is_installed dnsproxy; then
    log_fail "dnsproxy is not installed"
    return 1
  fi

  if systemctl is-active --quiet dnsproxy; then
    log_ok "dnsproxy service active"
  else
    log_fail "dnsproxy service is not active"
    log_info "Debug: journalctl -u dnsproxy -n 30 --no-pager"
    rc=1
  fi

  if dnsproxy_listening_on "$listen_address" "$listen_port"; then
    log_ok "listening on ${listen_address}:${listen_port}"
  else
    log_fail "nothing listening on ${listen_address}:${listen_port}"
    rc=1
  fi

  if ! dns_verify_routing "$listen_address" "$listen_port" "$upstream"; then rc=1; fi
  if ! getent hosts example.com >/dev/null 2>&1; then log_fail 'System name resolution failed'; rc=1; fi
  if verify_doh_resolves "$listen_address" "$listen_port"; then
    log_ok "direct query to the configured DNS proxy succeeds"
  else
    log_fail "name resolution failed"
    log_info "Recovery: sudo vm-init repair dns --with-fallback"
    rc=1
  fi

  return "$rc"
}

# Use brackets for an IPv6 resolver with a non-default port.
dns_target() {
  local addr="$1" port="$2"
  if [[ "$port" == 53 ]]; then printf '%s\n' "$addr"
  elif [[ "$addr" == *:* ]]; then printf '[%s]:%s\n' "$addr" "$port"
  else printf '%s:%s\n' "$addr" "$port"; fi
}

dns_verify_routing() {
  local addr="$1" port="$2" upstream="$3" target unit dns domains rc=0
  target=$(dns_target "$addr" "$port")
  unit=$(systemctl show dnsproxy --property=ExecStart --value) || return 1
  if [[ "$unit" != *"--upstream=${upstream} "* || "$unit" != *"--listen=${addr} "* || "$unit" != *"--port=${port} "* ]]; then
    log_fail 'Running dnsproxy service configuration differs from the requested upstream or listener'
    rc=1
  fi
  if ! systemctl is-active --quiet systemd-resolved; then
    log_fail 'systemd-resolved is not active'; rc=1
  fi
  if [[ "$(readlink "${VM_INIT_DNS_ROOT:-}/etc/resolv.conf")" != /run/systemd/resolve/stub-resolv.conf ]]; then
    log_fail 'resolv.conf does not use the systemd-resolved stub'; rc=1
  fi
  dns=$(LC_ALL=C resolvectl dns) || return 1
  domains=$(LC_ALL=C resolvectl domain) || return 1
  # resolved may list the same endpoint more than once. Every reported
  # endpoint must match; duplicate entries are not a different DNS route.
  if ! awk -v target="$target" '$1 == "Global:" { for(i=2;i<=NF;i++) { found=1; if($i != target) different=1 } } END { exit (!found || different) }' <<< "$dns"; then
    log_fail "Effective global DNS differs: expected only ${target}; observed $(awk '/^Global:/ { sub(/^Global:[[:space:]]*/, ""); print }' <<< "$dns")"
    log_info 'Inspect active resolver settings with: resolvectl dns'
    rc=1
  fi
  local iface
  while read -r iface; do
    [[ -n "$iface" ]] || continue
    if ! awk -v iface="($iface):" -v target="$target" '$3 == iface { for(i=4;i<=NF;i++) { found=1; if($i != target) different=1 } } END { exit (!found || different) }' <<< "$dns" \
       || ! awk -v iface="($iface):" '$3 == iface { for(i=4;i<=NF;i++) if($i == "~.") found=1 } END { exit !found }' <<< "$domains"; then
      log_fail "DNS routing on ${iface} is not pinned to the local proxy"; rc=1
    fi
  done < <({ ip -4 route show default; ip -6 route show default; } | awk '/^default / { for(i=1;i<NF;i++) if($i == "dev") print $(i+1) }' | sort -u)
  return "$rc"
}

dns_config_paths() {
  printf '%s\n' /etc/resolv.conf /etc/systemd/system/dnsproxy.service \
    /etc/systemd/system/vm-init-dns-pin.service \
    /etc/systemd/system/systemd-resolved.service.d/10-vm-init-dnsproxy.conf \
    /etc/systemd/resolved.conf.d/99-vm-init-dnsproxy.conf /usr/local/sbin/vm-init-dns-pin
}

dns_file_manifest() {
  local root="$1" result='{}' suffix value
  while read -r suffix; do
    value=$(reconcile_file_value "$root$suffix") || return 1
    result=$(jq -cS --arg path "$suffix" --arg value "$value" '. + {($path):$value}' <<< "$result") || return 1
  done < <(dns_config_paths)
  value=$(reconcile_file_value "$root/etc/systemd/resolved.conf.d/00-recovery-dns.conf") || return 1
  jq -cS --arg value "$value" '. + {recovery:$value}' <<< "$result"
}

dns_observe_spec() {
  local spec="$1" files services='{}' service value effective=true
  files=$(dns_file_manifest "${VM_INIT_DNS_ROOT:-}") || return 1
  for service in dnsproxy systemd-resolved vm-init-dns-pin; do
    value=$(systemctl is-enabled "$service" 2>/dev/null) || { [[ -n "$value" ]] || value=absent; }
    services=$(jq -cS --arg service "$service" --arg value "$value" '. + {($service):$value}' <<< "$services") || return 1
  done
  # A stopped enabled service can be started without rewriting its files.
  # Effective routing is checked when both providers are running, then checked
  # again after activation. Network reachability is a health check, not drift.
  if systemctl is-active --quiet dnsproxy && systemctl is-active --quiet systemd-resolved; then
    if ! dns_verify_routing "$(jq -r '.listen' <<< "$spec")" "$(jq -r '.port' <<< "$spec")" "$(jq -r '.upstream' <<< "$spec")" >/dev/null 2>&1; then effective=false; fi
    local unit bootstrap
    unit=$(systemctl show dnsproxy --property=ExecStart --value) || return 1
    while read -r bootstrap; do
      [[ "$unit" == *"--bootstrap $bootstrap "* ]] || effective=false
    done < <(jq -r '.bootstrap[]' <<< "$spec")
  fi
  jq -cS --argjson files "$files" --argjson services "$services" --argjson effective "$effective" \
    '.files=$files | .services=$services | .effective=$effective' <<< "$spec"
}

dns_prepare() {
  local saved old old_observed legacy=0 files bootstrap
  DNS_STAGE=$(mktemp -d) || return 1
  if ! (VM_INIT_DNS_ROOT="$DNS_STAGE" render_dns_config >/dev/null); then rm -rf "$DNS_STAGE"; return 1; fi
  files=$(dns_file_manifest "$DNS_STAGE") || { rm -rf "$DNS_STAGE"; return 1; }
  bootstrap=$(yq -r '.dns.bootstrap // ["9.9.9.9", "149.112.112.112"] | @json' "$CONFIG") || return 1
  DNS_DESIRED=$(jq -cnS --argjson files "$files" --arg upstream "$(dns_upstream_from_config)" \
    --arg listen "$(yq_get '.dns.listen_address' 127.0.0.1 "$CONFIG")" --arg port "$(yq_get '.dns.listen_port' 5353 "$CONFIG")" \
    --argjson bootstrap "$bootstrap" '{files:$files,upstream:$upstream,listen:$listen,port:$port,bootstrap:$bootstrap,
      services:{dnsproxy:"enabled","systemd-resolved":"enabled","vm-init-dns-pin":"enabled"},effective:true}') || return 1
  DNS_OBSERVED=$(dns_observe_spec "$DNS_DESIRED") || return 1
  saved=$(reconcile_load dns.configuration) || return 1
  if [[ "$saved" != null && "$DNS_OBSERVED" != "$DNS_DESIRED" ]]; then
    old=$(jq -r '.desired' <<< "$saved")
    old_observed=$(dns_observe_spec "$old") || return 1
    if [[ "$old_observed" == "$(jq -r '.observed' <<< "$saved")" ]]; then DNS_OBSERVED="$old_observed"; fi
  fi
  if reconcile_legacy dns || [[ -f "${VM_INIT_DNS_ROOT:-}/etc/systemd/system/dnsproxy.service" ]]; then legacy=1; fi
  reconcile_decide dns.configuration "$DNS_DESIRED" "$DNS_OBSERVED" "$legacy"
}

inspect_dns() (
  DNS_STAGE=''
  trap '[[ -z "$DNS_STAGE" ]] || rm -rf "$DNS_STAGE"' EXIT
  dns_prepare
)

install_dns() (
  set -e
  DNS_STAGE=''
  trap '[[ -z "$DNS_STAGE" ]] || rm -rf "$DNS_STAGE"' EXIT
  require_commands dpkg jq systemctl getent ss || return 1
  dns_prepare || return 1
  if [[ "$RECONCILE_ACTION" == drift ]]; then rm -rf "$DNS_STAGE"; return 0; fi
  if [[ "$RECONCILE_ACTION" == unchanged ]] && ! should_force; then
    local service
    for service in dnsproxy systemd-resolved vm-init-dns-pin; do
      if ! systemctl is-active --quiet "$service"; then
        run_quiet systemctl start "$service" || { rm -rf "$DNS_STAGE"; return 1; }
        reconcile_report "dns.runtime.$service" in_sync active active 'service started' true
      fi
    done
    if ! verify_dns; then rm -rf "$DNS_STAGE"; return 1; fi
    reconcile_accept dns.configuration "$DNS_DESIRED" "$DNS_OBSERVED" || { rm -rf "$DNS_STAGE"; return 1; }
    rm -rf "$DNS_STAGE"
    log_ok 'DNS configuration unchanged'
    return 0
  fi
  reconcile_begin dns.configuration "$DNS_DESIRED" "$DNS_OBSERVED" || { rm -rf "$DNS_STAGE"; return 1; }
  mkdir -p "$VM_INIT_STATE_DIR"
  snapshot="" committed=0
  snapshot=$(mktemp -d "$VM_INIT_STATE_DIR/dns-transaction.XXXXXX")
  dns_save_state "$snapshot" || { rm -rf "$snapshot"; return 1; }
  trap '
    rc=$?
    rm -rf "$DNS_STAGE"
    if [[ "$committed" != 1 ]]; then
      log_warn "DNS setup failed; restoring the previous configuration"
      if ! dns_restore_state "$snapshot"; then
        log_fail "Automatic DNS restoration failed; backup retained at $snapshot"
        exit 1
      fi
      log_ok "Previous DNS configuration restored"
    fi
    rm -rf "$snapshot"
    exit "$rc"
  ' EXIT
  if ! install_dnsproxy_binary; then
    log_fail 'DoH/DoT is NOT active: dnsproxy could not be installed'
    return 1
  fi
  ensure_systemd_resolved
  if ! command -v dig >/dev/null; then run_quiet apt_get install -y -q dnsutils; fi
  _configure_dns
  dns_verify_routing "$(yq_get '.dns.listen_address' 127.0.0.1 "$CONFIG")" \
    "$(yq_get '.dns.listen_port' 5353 "$CONFIG")" "$(dns_upstream_from_config)"
  if [[ ! -d "$VM_INIT_STATE_DIR/dns-original" ]]; then
    cp -a "$snapshot" "$VM_INIT_STATE_DIR/dns-original"
  fi
  verify_dns
  reconcile_accept dns.configuration "$DNS_DESIRED" "$DNS_DESIRED" true
  committed=1
  log_ok "DNS routing verified through $(dns_upstream_from_config)"
  vm_init_note "DNS now goes through dnsproxy. If it breaks: sudo vm-init repair dns --with-fallback"
)
