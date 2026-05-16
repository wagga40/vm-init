#!/usr/bin/env bash
# GitHub release binary installer module.
# Reads: CONFIG (path to vm-init.yml)
# Uses: download_github_release, github_release_decide from _common.sh

# --- Generic installer (config-driven) ---

install_github_releases_generic() {
  local count
  count=$(yq '.github_releases.generic | length' "$CONFIG")

  local i
  for ((i = 0; i < count; i++)); do
    local repo binary asset_pattern arch_value
    repo=$(yq ".github_releases.generic[$i].repo" "$CONFIG")
    binary=$(yq ".github_releases.generic[$i].binary" "$CONFIG")
    asset_pattern=$(yq ".github_releases.generic[$i].asset_pattern" "$CONFIG")

    local sys_arch
    sys_arch=$(dpkg --print-architecture)
    arch_value=$(yq ".github_releases.generic[$i].arch_map.${sys_arch} // \"${sys_arch}\"" "$CONFIG")

    download_github_release "$repo" "$asset_pattern" "$binary" "$arch_value"
  done
}

# --- Custom installers (bespoke logic per tool) ---
#
# Each handler follows the same shape:
#   1. Fetch latest tag.
#   2. Ask github_release_decide what to do.
#   3. If "current": log_current and return.
#   4. Otherwise: download/install, persist tag in state file, log accordingly.

install_bandwhich() {
  log_step "bandwhich"

  local tag
  tag=$(github_latest_version "imsnif/bandwhich") || return 1

  local decision action old
  decision=$(github_release_decide "bandwhich" "bandwhich" "$tag")
  action="${decision%% *}"
  old="${decision#"${action}"}"; old="${old# }"

  if [[ "$action" == "current" ]]; then
    log_current "bandwhich" "$old"
    return 0
  fi

  local sys_arch target asset_url tmp
  sys_arch=$(dpkg --print-architecture)
  [[ "$sys_arch" == amd64 ]] && target="x86_64-unknown-linux-musl" || target="aarch64-unknown-linux-musl"
  asset_url="https://github.com/imsnif/bandwhich/releases/download/${tag}/bandwhich-${tag}-${target}.tar.gz"

  tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf -- '${tmp}'" RETURN

  if ! download_file "$asset_url" "$tmp/bandwhich.tar.gz"; then
    log_fail "Failed to download bandwhich from ${asset_url}"
    return 1
  fi
  try_verify_github_asset "$tmp/bandwhich.tar.gz" "${asset_url}.sha256" || return 1
  if ! run_quiet tar xzf "$tmp/bandwhich.tar.gz" -C /usr/local/bin bandwhich; then
    log_fail "Failed to extract bandwhich"
    return 1
  fi
  chmod +x /usr/local/bin/bandwhich

  state_set "github_release.bandwhich" "$tag"

  if [[ "$action" == "upgrade" ]]; then
    log_upgraded "bandwhich" "$old" "$tag"
  else
    log_installed "bandwhich" "$tag"
  fi
}

install_vortix() {
  log_step "vortix"

  local tag
  tag=$(github_latest_version "Harry-kp/vortix") || return 1

  local decision action old
  decision=$(github_release_decide "vortix" "vortix" "$tag")
  action="${decision%% *}"
  old="${decision#"${action}"}"; old="${old# }"

  if [[ "$action" == "current" ]]; then
    log_current "vortix" "$old"
    return 0
  fi

  local installer_url installer
  installer_url="https://github.com/Harry-kp/vortix/releases/download/${tag}/vortix-installer.sh"
  installer=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f -- '${installer}'" RETURN

  if ! download_file "$installer_url" "$installer"; then
    log_fail "Failed to download vortix installer from ${installer_url}"
    return 1
  fi
  log_info "vortix installer sha256: $(_sha256_of "$installer" 2>/dev/null || echo '<unavailable>')"

  if ! run_quiet env CARGO_DIST_FORCE_INSTALL_DIR=/usr/local sh "$installer"; then
    log_fail "vortix installer exited non-zero"
    return 1
  fi

  state_set "github_release.vortix" "$tag"

  if [[ "$action" == "upgrade" ]]; then
    log_upgraded "vortix" "$old" "$tag"
  else
    log_installed "vortix" "$tag"
  fi
}

install_somo() {
  local sys_arch
  sys_arch=$(dpkg --print-architecture)
  if [[ "$sys_arch" != "amd64" ]]; then
    log_skip "somo: only amd64 .deb available (skip on ${sys_arch})"
    return 0
  fi

  log_step "somo"

  local auth_args=() release_json deb_url tag
  mapfile -t auth_args < <(_github_auth_args)
  if ! release_json=$(curl_retry "${auth_args[@]}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/theopfr/somo/releases/latest"); then
    log_fail "Failed to fetch somo release metadata"
    return 1
  fi
  tag=$(echo "$release_json" | jq -r '.tag_name')
  deb_url=$(echo "$release_json" \
    | jq -r '.assets[] | select(.name | endswith(".deb")) | .browser_download_url' \
    | head -1)

  if [[ -z "$deb_url" || "$deb_url" == "null" ]]; then
    log_warn "No .deb found in latest somo release — install manually: cargo install somo"
    return 0
  fi

  local decision action old
  decision=$(github_release_decide "somo" "somo" "$tag")
  action="${decision%% *}"
  old="${decision#"${action}"}"; old="${old# }"

  if [[ "$action" == "current" ]]; then
    log_current "somo" "$old"
    return 0
  fi

  local deb_tmp
  deb_tmp=$(mktemp --suffix=.deb)
  # shellcheck disable=SC2064
  trap "rm -f -- '${deb_tmp}'" RETURN

  if ! download_file "$deb_url" "$deb_tmp"; then
    log_fail "Failed to download somo .deb"
    return 1
  fi
  try_verify_github_asset "$deb_tmp" "${deb_url}.sha256" || return 1
  if ! run_quiet dpkg -i "$deb_tmp"; then
    log_fail "dpkg -i failed for somo"
    return 1
  fi

  state_set "github_release.somo" "$tag"

  if [[ "$action" == "upgrade" ]]; then
    log_upgraded "somo" "$old" "$tag"
  else
    log_installed "somo" "$tag"
  fi
}

install_systemd_manager_tui() {
  local sys_arch
  sys_arch=$(dpkg --print-architecture)
  case "$sys_arch" in
    amd64|arm64) ;;
    *) log_skip "systemd-manager-tui: only amd64/arm64 .deb available (skip on ${sys_arch})"
       return 0 ;;
  esac

  log_step "systemd-manager-tui"

  local tag
  tag=$(github_latest_version "Matheus-git/systemd-manager-tui") || return 1

  local decision action old
  decision=$(github_release_decide "systemd-manager-tui" "systemd-manager-tui" "$tag")
  action="${decision%% *}"
  old="${decision#"${action}"}"; old="${old# }"

  if [[ "$action" == "current" ]]; then
    log_current "systemd-manager-tui" "$old"
    return 0
  fi

  local version deb_url deb_tmp
  version="${tag#v}"
  deb_url="https://github.com/Matheus-git/systemd-manager-tui/releases/download/${tag}/systemd-manager-tui_${version}_${sys_arch}.deb"

  deb_tmp=$(mktemp --suffix=.deb)
  # shellcheck disable=SC2064
  trap "rm -f -- '${deb_tmp}'" RETURN

  if ! download_file "$deb_url" "$deb_tmp"; then
    log_fail "Failed to download systemd-manager-tui from ${deb_url}"
    return 1
  fi
  try_verify_github_asset "$deb_tmp" "${deb_url}.sha256" || return 1
  if ! run_quiet dpkg -i "$deb_tmp"; then
    log_fail "dpkg -i failed for systemd-manager-tui"
    return 1
  fi

  state_set "github_release.systemd-manager-tui" "$tag"

  if [[ "$action" == "upgrade" ]]; then
    log_upgraded "systemd-manager-tui" "$old" "$tag"
  else
    log_installed "systemd-manager-tui" "$tag"
  fi
}

install_fresh() {
  local sys_arch
  sys_arch=$(dpkg --print-architecture)
  case "$sys_arch" in
    amd64|arm64) ;;
    *) log_skip "fresh: only amd64/arm64 .deb available (skip on ${sys_arch})"
       return 0 ;;
  esac

  log_step "fresh"

  local tag
  tag=$(github_latest_version "sinelaw/fresh") || return 1

  local decision action old
  decision=$(github_release_decide "fresh" "fresh" "$tag")
  action="${decision%% *}"
  old="${decision#"${action}"}"; old="${old# }"

  if [[ "$action" == "current" ]]; then
    log_current "fresh" "$old"
    return 0
  fi

  local version deb_url deb_tmp
  version="${tag#v}"
  deb_url="https://github.com/sinelaw/fresh/releases/download/${tag}/fresh-editor_${version}-1_${sys_arch}.deb"

  deb_tmp=$(mktemp --suffix=.deb)
  # shellcheck disable=SC2064
  trap "rm -f -- '${deb_tmp}'" RETURN

  if ! download_file "$deb_url" "$deb_tmp"; then
    log_fail "Failed to download fresh from ${deb_url}"
    return 1
  fi
  try_verify_github_asset "$deb_tmp" "${deb_url}.sha256" || return 1
  if ! run_quiet dpkg -i "$deb_tmp"; then
    log_fail "dpkg -i failed for fresh"
    return 1
  fi

  state_set "github_release.fresh" "$tag"

  if [[ "$action" == "upgrade" ]]; then
    log_upgraded "fresh" "$old" "$tag"
  else
    log_installed "fresh" "$tag"
  fi
}

install_bat() {
  local sys_arch target
  sys_arch=$(dpkg --print-architecture)
  case "$sys_arch" in
    amd64) target="x86_64-unknown-linux-gnu" ;;
    arm64) target="aarch64-unknown-linux-gnu" ;;
    *) log_skip "bat: no prebuilt binary for ${sys_arch}"; return 0 ;;
  esac

  log_step "bat"

  local tag
  tag=$(github_latest_version "sharkdp/bat") || return 1

  local decision action old
  decision=$(github_release_decide "bat" "bat" "$tag")
  action="${decision%% *}"
  old="${decision#"${action}"}"; old="${old# }"

  if [[ "$action" == "current" ]]; then
    log_current "bat" "$old"
    return 0
  fi

  local version asset asset_url tmp
  version="${tag#v}"
  asset="bat-v${version}-${target}.tar.gz"
  asset_url="https://github.com/sharkdp/bat/releases/download/${tag}/${asset}"

  tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf -- '${tmp}'" RETURN

  if ! download_file "$asset_url" "$tmp/${asset}"; then
    log_fail "Failed to download bat from ${asset_url}"
    return 1
  fi
  try_verify_github_asset "$tmp/${asset}" "${asset_url}.sha256" || return 1
  if ! run_quiet tar xzf "$tmp/${asset}" -C /usr/local/bin --strip-components=1 \
        "bat-v${version}-${target}/bat"; then
    log_fail "Failed to extract bat"
    return 1
  fi
  chmod +x /usr/local/bin/bat

  state_set "github_release.bat" "$tag"

  if [[ "$action" == "upgrade" ]]; then
    log_upgraded "bat" "$old" "$tag"
  else
    log_installed "bat" "$tag"
  fi
}

# --- Entry point ---

install_github_releases() {
  require_commands dpkg jq tar || return 1

  install_github_releases_generic

  local custom_tools=("bandwhich" "vortix" "somo" "systemd_manager_tui" "bat" "fresh")
  for tool in "${custom_tools[@]}"; do
    local enabled
    enabled=$(yq ".github_releases.custom.${tool} // false" "$CONFIG")
    if [[ "$enabled" == "true" ]]; then
      "install_${tool}"
    fi
  done
}
