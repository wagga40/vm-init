#!/usr/bin/env bash
# Yazi terminal file manager, installed from the upstream apt repository.
# Reads: CONFIG (path to vm-init.yml)

YAZI_KEYRING="/usr/share/keyrings/yazi-keyring.gpg"
YAZI_LIST="/etc/apt/sources.list.d/yazi.list"

install_yazi() {
  require_commands apt-get dpkg || return 1

  # Both artifacts must be present: a sources entry pointing at a missing
  # keyring makes every later `apt-get update` fail.
  if ! [[ -f "$YAZI_LIST" && -s "$YAZI_KEYRING" ]]; then
    log_step "Setting up Yazi apt repository"
    if ! download_file \
          "https://yazi-rs.github.io/builds/yazi-keyring.gpg" \
          "$YAZI_KEYRING"; then
      log_fail "Failed to download Yazi keyring"
      return 1
    fi
    chmod go+r "$YAZI_KEYRING"

    echo "deb [arch=$(dpkg --print-architecture) signed-by=${YAZI_KEYRING}] \
https://yazi-rs.github.io/builds/ stable main" \
      | tee "$YAZI_LIST" > /dev/null

    run_quiet apt_get update -q
  fi

  apt_install_with_report yazi
}

# Post-install verification: the apt repository is wired up and yazi is present.
verify_yazi() {
  require_commands dpkg-query || return 1

  local rc=0

  # A sources entry pointing at a missing keyring breaks every later
  # `apt-get update`, so check both halves, not just the binary.
  if [[ -f "$YAZI_LIST" && -s "$YAZI_KEYRING" ]]; then
    log_ok "yazi apt repository configured"
  else
    log_warn "yazi apt repository incomplete (list: ${YAZI_LIST}, keyring: ${YAZI_KEYRING})"
  fi

  if dpkg-query -W -f='${Status}' yazi 2>/dev/null | grep -q '^install ok installed$'; then
    log_ok "yazi installed ($(dpkg-query -W -f='${Version}' yazi 2>/dev/null))"
  else
    log_fail "yazi is not installed"
    rc=1
  fi

  return "$rc"
}
