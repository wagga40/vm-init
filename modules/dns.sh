#!/usr/bin/env bash
# DNS privacy client module using dnsproxy (DoH/DoT).
# Reads: CONFIG (path to vm-init.yml)

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
  server=$(yq '.dns.server // "https://base.dns.mullvad.net/dns-query"' "$CONFIG")

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
    if ! run_quiet apt-get install -y -qq systemd-resolved; then
      log_fail "Failed to install systemd-resolved package"
      return 1
    fi
  fi

  if ! systemctl is-enabled --quiet systemd-resolved 2>/dev/null; then
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

default_route_interfaces() {
  ip -4 route show default 2>/dev/null | awk '/^default /{print $5}' | sort -u
  ip -6 route show default 2>/dev/null | awk '/^default /{print $5}' | sort -u
}

pin_resolved_links_to_local() {
  local local_dns_target="$1"
  if ! is_installed resolvectl; then
    log_skip "resolvectl not found; skip per-link DNS pinning"
    return 0
  fi

  local default_links
  default_links=$(default_route_interfaces | sort -u)

  if [[ -z "$default_links" ]]; then
    log_skip "No default-route links found for resolvectl pinning"
    return 0
  fi

  log_step "Pinning default-route links to local DNS"
  local iface
  while IFS= read -r iface; do
    [[ -z "$iface" ]] && continue
    if ! resolvectl dns "$iface" "$local_dns_target" >/dev/null 2>&1; then
      log_warn "Could not pin DNS on ${iface} to ${local_dns_target} (non-fatal)"
      continue
    fi
    if ! resolvectl domain "$iface" "~." >/dev/null 2>&1; then
      log_warn "Could not set routing domain on ${iface} (non-fatal)"
      continue
    fi
  done <<< "$default_links"
}

dnsproxy_listening_on() {
  local addr="$1" port="$2"
  if command -v ss >/dev/null 2>&1; then
    # Match address:port (dnsproxy binds to $addr) or 0.0.0.0:port (wildcard bind)
    ss -lunH "sport = :${port}" 2>/dev/null \
      | awk -v addr="$addr" -v port="$port" '
        {
          for (i = 1; i <= NF; i++) {
            if ($i == addr ":" port || $i == "0.0.0.0:" port || $i == "*:" port) {
              found = 1
              exit
            }
          }
        }
        END { exit found ? 0 : 1 }
      '
  else
    return 0
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
    if getent hosts example.com >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

install_dns() {
  if ! install_dnsproxy_binary; then
    log_warn "DNS module skipped — dnsproxy binary could not be installed"
    log_warn "DoH/DoT is NOT active. DNS uses system defaults."
    log_info "Re-run with --force after resolving the issue, or set dns.enabled: false"
    return 0
  fi

  if ! ensure_systemd_resolved; then
    log_warn "DNS module skipped — systemd-resolved is unavailable"
    log_warn "DoH/DoT is NOT active. DNS uses system defaults."
    return 0
  fi

  local upstream listen_address listen_port
  if ! upstream=$(dns_upstream_from_config); then
    log_warn "DNS module skipped — invalid dns.server in config"
    return 0
  fi
  listen_address=$(yq '.dns.listen_address // "127.0.0.1"' "$CONFIG")
  listen_port=$(yq '.dns.listen_port // 5353' "$CONFIG")

  # systemd-resolved DNS= syntax: "address:port" (colon for port, hash is SNI).
  local resolved_dns_target="${listen_address}"
  if [[ "$listen_port" != "53" ]]; then
    resolved_dns_target="${listen_address}:${listen_port}"
  fi

  local bootstrap_flags=""
  local bs_line
  while IFS= read -r bs_line; do
    [[ -z "$bs_line" ]] && continue
    bootstrap_flags+=" --bootstrap ${bs_line}"
  done <<< "$(yq '.dns.bootstrap // ["9.9.9.9", "149.112.112.112"] | .[]' "$CONFIG")"

  log_step "Writing dnsproxy service"
  cat > /etc/systemd/system/dnsproxy.service <<EOF
[Unit]
Description=DNS over HTTPS/TLS proxy (dnsproxy)
Documentation=https://github.com/AdguardTeam/dnsproxy
After=network-online.target nss-lookup.target
Wants=network-online.target
Before=systemd-resolved.service

[Service]
Type=simple
ExecStart=/usr/local/bin/dnsproxy --upstream=${upstream} --listen=${listen_address} --port=${listen_port}${bootstrap_flags} --cache --upstream-mode=parallel
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  log_step "Pointing systemd-resolved to dnsproxy"
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/99-vm-init-dnsproxy.conf <<EOF
[Resolve]
DNS=${resolved_dns_target}
FallbackDNS=
Domains=~.
DNSStubListener=yes
EOF

  log_step "Ensuring resolv.conf uses the stub resolver"
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable dnsproxy >/dev/null 2>&1 || true
  if ! systemctl restart dnsproxy >/dev/null 2>&1; then
    log_warn "dnsproxy failed to start"
    log_info "Debug: journalctl -u dnsproxy -n 30 --no-pager"
    return 0
  fi

  if ! wait_for_dnsproxy "$listen_address" "$listen_port"; then
    log_warn "dnsproxy is not listening on ${listen_address}:${listen_port} after 5s"
    log_info "Debug: systemctl status dnsproxy --no-pager"
    log_info "Debug: journalctl -u dnsproxy -n 30 --no-pager"
    log_info "Debug: ss -lunp | grep ${listen_port}"
    log_info "Recovery: modules/recover-dns.sh --with-fallback"
    return 0
  fi

  systemctl restart systemd-resolved >/dev/null 2>&1 || true
  pin_resolved_links_to_local "$resolved_dns_target"

  if verify_doh_resolves; then
    log_ok "dnsproxy configured and resolving via ${upstream}"
  else
    log_warn "dnsproxy is listening but DNS resolution failed"
    log_info "Debug: resolvectl status"
    log_info "Debug: resolvectl query example.com"
    log_info "Debug: journalctl -u dnsproxy -n 30 --no-pager"
    log_info "Recovery: modules/recover-dns.sh --with-fallback"
  fi
}
