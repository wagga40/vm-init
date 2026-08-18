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
