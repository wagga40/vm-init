#!/usr/bin/env bash
# Docker engine + compose installation module.

install_docker() {
  require_commands apt-get dpkg gpg lsb_release systemctl || return 1

  if ! [[ -f /etc/apt/sources.list.d/docker.list ]]; then
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

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      | tee /etc/apt/sources.list.d/docker.list > /dev/null

    run_quiet apt_get update -q
  fi

  apt_install_group_with_report "docker" docker-ce \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1

  local first_user
  first_user=$(human_users | head -1 | cut -d: -f1)
  if [[ -n "${first_user:-}" ]]; then
    if ! id -nG "$first_user" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
      usermod -aG docker "$first_user"
      log_info "Added ${first_user} to docker group (log out/in for group to apply)"
      vm_init_note "Log out and back in for ${first_user}'s docker group membership to apply."
    fi
  fi

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

  return "$rc"
}
