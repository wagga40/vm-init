#!/usr/bin/env bash
# Docker engine + compose installation module.

install_docker() {
  require_commands apt-get dpkg systemctl || return 1
  ensure_apt_packages ca-certificates curl gnupg lsb-release || return 1

  local repository_rc=0
  docker_repository apply || repository_rc=$?
  if [[ "$repository_rc" == 2 ]]; then
    if ! is_installed docker; then
      log_warn 'Docker installation needs the repository drift resolved first'
      return 0
    fi
  elif [[ "$repository_rc" != 0 ]]; then return 1
  else
    apt_install_group_with_report "docker" docker-ce \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
  fi

  local user key actual legacy=0
  if reconcile_legacy docker; then legacy=1; fi
  for user in ${VM_INIT_TARGET_USERS:-}; do
    [[ "$user" != root ]] || continue
    key="docker.group.$(getent passwd "$user" | awk -F: '{print $1 ":" $3 ":" $6}' | _sha256_stdin)"
    actual=absent
    if id -nG "$user" | tr ' ' '\n' | grep -qx docker; then actual=present; fi
    # Account-specific baselines distinguish newly selected accounts from
    # administrator removals on accounts we previously configured.
    local account_legacy=0
    if reconcile_account_legacy docker "$user"; then account_legacy=1; fi
    reconcile_decide "$key" present "$actual" "$account_legacy" || return 1
    if [[ "$RECONCILE_ACTION" == drift ]]; then continue; fi
    if [[ "$RECONCILE_ACTION" == apply ]]; then
      reconcile_begin "$key" present "$actual" || return 1
      usermod -aG docker "$user" || return 1
      id -nG "$user" | tr ' ' '\n' | grep -qx docker || return 1
      reconcile_accept "$key" present present true || return 1
      vm_init_note "Log out and back in for ${user}'s docker group membership to apply." session
    else reconcile_accept "$key" present present || return 1; fi
  done
  local service_rc=0
  reconcile_service docker docker "$legacy" || service_rc=$?
  if [[ "$service_rc" == 2 ]]; then return 0; fi
  return "$service_rc"
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


docker_repository() {
  local root="${VM_INIT_SYSTEM_ROOT:-}"
  reconcile_repository docker "$root/etc/apt/sources.list.d/docker.list" "$root/etc/apt/keyrings/docker.gpg" \
    https://download.docker.com/linux/ubuntu/gpg \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" "${1:-inspect}"
}

inspect_docker() {
  local rc=0 user key actual
  docker_repository inspect || rc=$?
  [[ "$rc" == 0 || "$rc" == 2 ]] || return "$rc"
  inspect_service docker docker || return 1
  for user in ${VM_INIT_TARGET_USERS:-}; do
    [[ "$user" != root ]] || continue
    key="docker.group.$(getent passwd "$user" | awk -F: '{print $1 ":" $3 ":" $6}' | _sha256_stdin)"
    actual=absent
    if id -nG "$user" | tr ' ' '\n' | grep -qx docker; then actual=present; fi
    local account_legacy=0
    if reconcile_account_legacy docker "$user"; then account_legacy=1; fi
    reconcile_decide "$key" present "$actual" "$account_legacy" || return 1
  done
  return 0
}
