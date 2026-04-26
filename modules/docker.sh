#!/usr/bin/env bash
# Docker engine + compose installation module.

install_docker() {
  require_commands apt-get dpkg gpg lsb_release systemctl || return 1

  if is_installed docker && ! should_force; then
    log_skip "Docker already installed"
    return 0
  fi

  log_step "Installing Docker"
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

  run_quiet apt-get update -qq
  run_quiet apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

  local first_user
  first_user=$(human_users | head -1 | cut -d: -f1)
  if [[ -n "${first_user:-}" ]]; then
    usermod -aG docker "$first_user"
    log_info "Added ${first_user} to docker group (log out/in for group to apply)"
  fi

  run_quiet systemctl enable docker
  run_quiet systemctl start docker
  log_ok "Docker installed and started"
}
