#!/usr/bin/env bash
# Docker engine + compose installation module.

install_docker() {
  require_commands apt-get dpkg systemctl || return 1
  ensure_apt_packages ca-certificates curl gnupg lsb-release || return 1

  if ! [[ -f /etc/apt/sources.list.d/docker.list && -s /etc/apt/keyrings/docker.gpg ]]; then
    log_step "Setting up Docker apt repository"
    mkdir -p /etc/apt/keyrings

    local gpg_tmp
    gpg_tmp=$(mktemp)
    if ! download_file "https://download.docker.com/linux/ubuntu/gpg" "$gpg_tmp"; then
      rm -f "$gpg_tmp"
      log_fail "Failed to download Docker GPG key"
      return 1
    fi
    run_quiet bash -c "gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg < '$gpg_tmp'"
    rm -f "$gpg_tmp"
    chmod 644 /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      | tee /etc/apt/sources.list.d/docker.list > /dev/null

    run_quiet apt_get update -q
  fi

  apt_install_group_with_report "docker" docker-ce \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1

  local user
  for user in ${VM_INIT_TARGET_USERS:-}; do
    [[ "$user" != root ]] || continue
    if ! id -nG "$user" | tr ' ' '\n' | grep -qx docker; then
      usermod -aG docker "$user" || return 1
      vm_init_note "Log out and back in for ${user}'s docker group membership to apply."
    fi
  done

  run_quiet systemctl enable docker
  run_quiet systemctl start docker
}

# Post-install verification: the daemon is up, reachable, and the compose plugin
# is wired in. `docker info` is the check that actually proves the socket works.
verify_docker() {
  require_commands systemctl || return 1

  local rc=0

  if ! is_installed docker; then
    log_fail "docker is not installed"
    return 1
  fi

  if systemctl is-active --quiet docker; then
    log_ok "docker service active"
  else
    log_fail "docker service is not active"
    rc=1
  fi

  if run_quiet docker info; then
    log_ok "docker daemon reachable"
  else
    log_fail "docker info failed — daemon unreachable"
    rc=1
  fi

  if run_quiet docker compose version; then
    log_ok "docker compose plugin present"
  else
    log_fail "docker compose plugin missing"
    rc=1
  fi

  local user
  for user in ${VM_INIT_TARGET_USERS:-}; do
    [[ "$user" != root ]] || continue
    if ! id -nG "$user" | tr ' ' '\n' | grep -qx docker; then
      log_fail "${user} is not in the docker group"; rc=1
    fi
  done
  return "$rc"
}
