#!/usr/bin/env bash
# Paths and installation lifecycle shared by the CLI, installer, and bundle.
# shellcheck disable=SC2034 # exports shared shell state to the orchestrator

uses_legacy_layout() {
  [[ "$VM_INIT_PREFIX" == /opt/vm-init || -n "${VM_INIT_LEGACY_ROOT:-}" \
    || -f "$VM_INIT_PREFIX/.vm-init-managed" ]]
}

init_layout() {
  local executable directory
  executable=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
  directory=$(cd "$(dirname "$executable")" && pwd)
  if [[ "${directory##*/}" == modules && -f "${directory%/modules}/.vm-init-managed" ]]; then directory=${directory%/modules}; fi
  if [[ -f "$directory/.vm-init-managed" ]]; then
    local managed_bin managed_no_symlink
    { read -r managed_bin; read -r managed_no_symlink; } < "$directory/.vm-init-managed" || return 1
    : "${VM_INIT_BIN_DIR:=$managed_bin}" "${VM_INIT_NO_SYMLINK:=$managed_no_symlink}"
  fi
  if [[ -z "${VM_INIT_PREFIX:-}" && -f "$directory/.vm-init-managed" ]]; then
    if [[ "${directory##*/}" == app ]]; then VM_INIT_PREFIX=${directory%/app}
    else VM_INIT_PREFIX=$directory; fi
  fi
  : "${VM_INIT_PREFIX:=/opt/vm-init}"
  while [[ "$VM_INIT_PREFIX" != / && "$VM_INIT_PREFIX" == */ ]]; do VM_INIT_PREFIX=${VM_INIT_PREFIX%/}; done
  : "${VM_INIT_BIN_DIR:=/usr/local/bin}"
  : "${VM_INIT_NO_SYMLINK:=0}"
  : "${VM_INIT_LEGACY_ROOT:=}"
  VM_INIT_CONFIG_DIR="$VM_INIT_PREFIX/config"
  VM_INIT_LOG_DIR="$VM_INIT_PREFIX/logs"
  VM_INIT_CANONICAL_STATE_DIR="${VM_INIT_STATE_DIR:-$VM_INIT_PREFIX/state}"
  VM_INIT_STATE_DIR="$VM_INIT_CANONICAL_STATE_DIR"
  # Read-only commands and offline recovery can use unmigrated installations.
  if uses_legacy_layout \
      && [[ "$VM_INIT_CANONICAL_STATE_DIR" == "$VM_INIT_PREFIX/state" ]] \
      && [[ ! -e "$VM_INIT_STATE_DIR" && -d "$VM_INIT_LEGACY_ROOT/var/lib/vm-init" && ! -L "$VM_INIT_LEGACY_ROOT/var/lib/vm-init" ]]; then
    VM_INIT_STATE_DIR="$VM_INIT_LEGACY_ROOT/var/lib/vm-init"
  fi
  : "${VM_INIT_STATE_FILE:=$VM_INIT_STATE_DIR/state}"
  PATH="$VM_INIT_PREFIX/bin:$PATH"
  export VM_INIT_PREFIX VM_INIT_BIN_DIR VM_INIT_NO_SYMLINK PATH
}

validate_install_prefix() {
  case "$VM_INIT_PREFIX" in
    ''|/|/etc|/usr|/usr/local|/opt|/root|/home|*..*)
      log_fail 'Choose a dedicated absolute installation directory'; return 1 ;;
    /*) ;;
    *) log_fail 'The installation prefix must be an absolute path'; return 1 ;;
  esac
  if [[ -L "$VM_INIT_PREFIX" ]]; then log_fail 'The installation prefix must not be a symlink'; return 1; fi
}

select_config() {
  [[ "${CONFIG_EXPLICIT:-0}" != 1 ]] || return 0
  VM_INIT_CONFIG_ORIGIN='shipped default'
  CONFIG="$SCRIPT_DIR/vm-init.yml"
  if [[ -d "$VM_INIT_CONFIG_DIR" && ! -x "$VM_INIT_CONFIG_DIR" ]]; then
    log_fail "Cannot read configuration directory: $VM_INIT_CONFIG_DIR"; return 1
  fi
  if [[ -e "$VM_INIT_CONFIG_DIR/vm-init.yml" || -L "$VM_INIT_CONFIG_DIR/vm-init.yml" ]]; then
    CONFIG="$VM_INIT_CONFIG_DIR/vm-init.yml"; VM_INIT_CONFIG_ORIGIN='saved configuration'
  elif uses_legacy_layout \
      && [[ -e "$VM_INIT_LEGACY_ROOT/etc/vm-init/vm-init.yml" ]]; then
    CONFIG="$VM_INIT_LEGACY_ROOT/etc/vm-init/vm-init.yml"; VM_INIT_CONFIG_ORIGIN='legacy configuration'
  elif [[ -f "$VM_INIT_PREFIX/.vm-init-managed" && -f "$VM_INIT_PREFIX/vm-init.yml" ]]; then
    CONFIG="$VM_INIT_PREFIX/vm-init.yml"; VM_INIT_CONFIG_ORIGIN='legacy configuration'
  elif [[ -f "$PWD/vm-init.yml" && ! "$PWD/vm-init.yml" -ef "$SCRIPT_DIR/vm-init.yml" ]]; then
    CONFIG="$PWD/vm-init.yml"; VM_INIT_CONFIG_ORIGIN='current directory'
  fi
  if [[ ( -e "$CONFIG" || -L "$CONFIG" ) && ! -r "$CONFIG" ]]; then log_fail "Cannot read configuration: $CONFIG"; return 1; fi
}

layout_conflict() {
  log_fail "Both $1 and $2 contain installation data. Resolve the conflicting paths before retrying."
  return 1
}

# Keep old absolute paths valid for saved retries and recovery scripts.
layout_move_and_link() {
  local old="$1" destination="$2"
  [[ -e "$old" && ! "$old" -ef "$destination" ]] || return 0
  mkdir -p "$(dirname "$destination")" || return 1
  mv "$old" "$destination" || return 1
  if ! ln -s "$destination" "$old"; then
    mv "$destination" "$old" || log_fail "Restore $destination to $old before retrying migration"
    return 1
  fi
}

# Stage and lock the destination before exposing it. /opt and /var may be on
# different filesystems, so moving the original run.lock would change its inode.
migrate_state() {
  local old="$1" destination="$2" stage backup
  [[ -d "$old" && ! "$old" -ef "$destination" ]] || return 0
  install -d -m 0755 "$VM_INIT_PREFIX" || return 1
  stage=$(mktemp -d "$VM_INIT_PREFIX/.state-migration.XXXXXX") || return 1
  if ! cp -a "$old/." "$stage/"; then rm -rf "$stage"; return 1; fi
  exec {VM_INIT_NEW_LOCK_FD}>"$stage/run.lock"
  if ! flock -n "$VM_INIT_NEW_LOCK_FD"; then rm -rf "$stage"; return 1; fi
  backup=$(mktemp -d "${old}.migration.XXXXXX") || { rm -rf "$stage"; return 1; }
  rmdir "$backup" || return 1
  mv "$old" "$backup" || { rm -rf "$stage"; return 1; }
  if ! mv "$stage" "$destination"; then
    mv "$backup" "$old"; rm -rf "$stage"; return 1
  fi
  if ! ln -s "$destination" "$old"; then
    rm -rf "$destination"
    mv "$backup" "$old" || log_fail "Original state is preserved at $backup"
    return 1
  fi
  # Keep the old open description until exit; children inherit the new lock.
  VM_INIT_LOCK_FD="$VM_INIT_NEW_LOCK_FD"
  export VM_INIT_LOCK_FD
  rm -rf "$backup"
}

migrate_layout() {
  validate_install_prefix || return 1
  local legacy_state="$VM_INIT_LEGACY_ROOT/var/lib/vm-init" legacy_config="$VM_INIT_LEGACY_ROOT/etc/vm-init"
  local legacy_logs="$VM_INIT_LEGACY_ROOT/var/log" path destination old_state="$VM_INIT_STATE_DIR"
  if ! uses_legacy_layout; then return 0; fi
  # Preflight every collision before moving anything. Locks are kept open while
  # moving directories, so old and new commands serialize on the same inode.
  if [[ "$VM_INIT_CANONICAL_STATE_DIR" == "$VM_INIT_PREFIX/state" && -d "$legacy_state" && ! "$legacy_state" -ef "$VM_INIT_CANONICAL_STATE_DIR" ]]; then
    if [[ "$legacy_state" != "$VM_INIT_STATE_DIR" ]]; then
      exec {VM_INIT_LEGACY_LOCK_FD}>"$legacy_state/run.lock"
      flock -n "$VM_INIT_LEGACY_LOCK_FD" || { log_fail 'Another legacy vm-init change is running'; return 1; }
    fi
    exec {VM_INIT_MIGRATION_FIREWALL_FD}>"$legacy_state/firewall.lock"
    flock -n "$VM_INIT_MIGRATION_FIREWALL_FD" || { log_fail 'Firewall rollback is running; retry after it finishes'; return 1; }
    if [[ -f "$legacy_state/firewall-pending" ]]; then
      log_fail 'Confirm the pending firewall change or wait for rollback before migrating vm-init'; return 1
    fi
    if [[ -e "$VM_INIT_CANONICAL_STATE_DIR" ]]; then layout_conflict "$legacy_state" "$VM_INIT_CANONICAL_STATE_DIR"; return 1; fi
  fi
  if [[ -d "$legacy_config" && ! "$legacy_config" -ef "$VM_INIT_CONFIG_DIR" && -e "$VM_INIT_CONFIG_DIR" ]]; then
    layout_conflict "$legacy_config" "$VM_INIT_CONFIG_DIR"; return 1
  fi
  for path in "$legacy_logs"/vm-init-*.log; do
    [[ -e "$path" ]] || continue
    destination="$VM_INIT_LOG_DIR/${path##*/}"
    if [[ -e "$destination" && ! "$path" -ef "$destination" ]]; then layout_conflict "$path" "$destination"; return 1; fi
  done
  if [[ "$VM_INIT_CANONICAL_STATE_DIR" == "$VM_INIT_PREFIX/state" ]]; then
    migrate_state "$legacy_state" "$VM_INIT_CANONICAL_STATE_DIR" || return 1
    VM_INIT_STATE_DIR="$VM_INIT_CANONICAL_STATE_DIR"
    if [[ "$VM_INIT_STATE_FILE" == "$old_state/state" ]]; then VM_INIT_STATE_FILE="$VM_INIT_STATE_DIR/state"; fi
  fi
  layout_move_and_link "$legacy_config" "$VM_INIT_CONFIG_DIR" || return 1
  for path in "$legacy_logs"/vm-init-*.log; do
    [[ -e "$path" ]] || continue
    layout_move_and_link "$path" "$VM_INIT_LOG_DIR/${path##*/}" || return 1
  done
  if [[ -n "${VM_INIT_MIGRATION_FIREWALL_FD:-}" ]]; then exec {VM_INIT_MIGRATION_FIREWALL_FD}>&-; fi
  if [[ -d "$VM_INIT_CONFIG_DIR" ]]; then chmod 0700 "$VM_INIT_CONFIG_DIR" || return 1; fi
  if [[ -d "$VM_INIT_LOG_DIR" ]]; then chmod 0700 "$VM_INIT_LOG_DIR" || return 1; fi
  if [[ -d "$VM_INIT_STATE_DIR" ]]; then chmod 0700 "$VM_INIT_STATE_DIR" || return 1; fi
  export VM_INIT_STATE_DIR VM_INIT_STATE_FILE
}

preserve_legacy_config() {
  if [[ -f "$VM_INIT_PREFIX/vm-init.sh" && ! -L "$VM_INIT_PREFIX/vm-init.sh" \
      && -f "$VM_INIT_PREFIX/vm-init.yml" && ! -e "$VM_INIT_CONFIG_DIR/vm-init.yml" ]]; then
    install -d -m 0700 "$VM_INIT_CONFIG_DIR" || return 1
    install -m 0600 "$VM_INIT_PREFIX/vm-init.yml" "$VM_INIT_CONFIG_DIR/vm-init.yml" || return 1
  fi
}

# Commit already validated code. Persistent data is never part of this swap.
install_app() (
  local stage="$1" entry="$2" backup='' committed=0 link old_target='' old_command='' command_path old_entry=''
  command_path="$VM_INIT_BIN_DIR/vm-init"
  if [[ -L "$VM_INIT_PREFIX/bin/vm-init" ]]; then old_entry=$(readlink "$VM_INIT_PREFIX/bin/vm-init"); fi
  if [[ -e "$VM_INIT_PREFIX/app" && ! -f "$VM_INIT_PREFIX/app/.vm-init-managed" ]]; then
    log_fail "Refusing to replace an unmanaged application directory: $VM_INIT_PREFIX/app"; return 1
  fi
  if [[ "$VM_INIT_NO_SYMLINK" != 1 && -e "$command_path" && ! -L "$command_path" ]]; then
    # A previous standalone distribution was installed as a regular file.
    if ! head -n 15 "$command_path" | grep -q 'vm-init.*single-file'; then
      log_fail "Refusing to replace an unrelated command: $command_path"; return 1
    fi
    old_command=$(mktemp "$VM_INIT_PREFIX/.old-command.XXXXXX") || return 1
    cp -p "$command_path" "$old_command" || return 1
  elif [[ -L "$command_path" ]]; then old_target=$(readlink "$command_path"); fi
  # shellcheck disable=SC2329 # EXIT trap
  cleanup_install_app() {
    local rc=$?
    if (( rc != 0 && committed )); then
      rm -rf "$VM_INIT_PREFIX/app"
      [[ -z "$backup" ]] || mv "$backup" "$VM_INIT_PREFIX/app"
      if [[ -n "$old_entry" ]]; then ln -sfn "$old_entry" "$VM_INIT_PREFIX/bin/vm-init"
      else rm -f "$VM_INIT_PREFIX/bin/vm-init"; fi
      if [[ "$VM_INIT_NO_SYMLINK" != 1 ]]; then
        if [[ -n "$old_command" ]]; then cp -p "$old_command" "$command_path"
        elif [[ -n "$old_target" ]]; then ln -sfn "$old_target" "$command_path"
        elif [[ -L "$command_path" ]]; then rm -f "$command_path"; fi
      fi
    fi
    [[ -z "$old_command" ]] || rm -f "$old_command"
    return "$rc"
  }
  trap cleanup_install_app EXIT
  printf '%s\n%s\n' "$VM_INIT_BIN_DIR" "$VM_INIT_NO_SYMLINK" > "$stage/.vm-init-managed"
  chmod 0755 "$stage" "$stage/$entry" || return 1
  chown -R root:root "$stage" || return 1
  mkdir -p "$VM_INIT_PREFIX/bin" || return 1
  if [[ -d "$VM_INIT_PREFIX/app" ]]; then
    backup=$(mktemp -d "$VM_INIT_PREFIX/.app-backup.XXXXXX") || return 1
    rmdir "$backup"
    mv "$VM_INIT_PREFIX/app" "$backup" || return 1
  fi
  committed=1
  mv "$stage" "$VM_INIT_PREFIX/app" || return 1
  link=$(mktemp "$VM_INIT_PREFIX/bin/.command.XXXXXX") || return 1
  rm -f "$link"
  ln -s "../app/$entry" "$link" && mv -f "$link" "$VM_INIT_PREFIX/bin/vm-init" || return 1
  if [[ "$VM_INIT_NO_SYMLINK" != 1 && ! "$VM_INIT_BIN_DIR" -ef "$VM_INIT_PREFIX/bin" ]]; then
    mkdir -p "$VM_INIT_BIN_DIR" || return 1
    ln -sfn "$VM_INIT_PREFIX/bin/vm-init" "$command_path" || return 1
  fi
  [[ -z "$backup" ]] || rm -rf "$backup"
)

install_running_bundle() {
  [[ ! "$VM_INIT_RESOLVED_EXECUTABLE" -ef "$VM_INIT_PREFIX/app/vm-init" ]] || return 0
  local stage
  install -d -m 0755 "$VM_INIT_PREFIX" || return 1
  stage=$(mktemp -d "$VM_INIT_PREFIX/.bundle.XXXXXX") || return 1
  if ! { cp "$VM_INIT_RESOLVED_EXECUTABLE" "$stage/vm-init" \
    && cmp -s "$VM_INIT_RESOLVED_EXECUTABLE" "$stage/vm-init" \
    && bash -n "$stage/vm-init" \
    && install_app "$stage" vm-init; }; then rm -rf "$stage"; return 1; fi
  SCRIPT_NAME=vm-init
  VM_INIT_EXECUTABLE="$VM_INIT_PREFIX/bin/vm-init"
  VM_INIT_RESOLVED_EXECUTABLE="$VM_INIT_PREFIX/app/vm-init"
  log_ok "Installed vm-init at $VM_INIT_PREFIX"
}

# Old entry points remain usable after moving flat tarball installations.
link_legacy_app() {
  [[ -f "$VM_INIT_PREFIX/vm-init.sh" && ! -L "$VM_INIT_PREFIX/vm-init.sh" ]] || return 0
  local item
  for item in vm-init.sh modules scripts VERSION vm-init.yml README.md LICENSE docs .vm-init-managed; do
    [[ -e "$VM_INIT_PREFIX/$item" ]] || continue
    [[ -e "$VM_INIT_PREFIX/app/$item" ]] || continue
    rm -rf "${VM_INIT_PREFIX:?}/$item" || return 1
    if [[ "$item" == vm-init.yml ]]; then
      ln -s config/vm-init.yml "$VM_INIT_PREFIX/$item" || return 1
    else
      ln -s "app/$item" "$VM_INIT_PREFIX/$item" || return 1
    fi
  done
}

migrate_flat_app() {
  [[ -f "$VM_INIT_PREFIX/vm-init.sh" && ! -L "$VM_INIT_PREFIX/vm-init.sh" && ! -e "$VM_INIT_PREFIX/app" ]] || return 0
  local stage item
  stage=$(mktemp -d "$VM_INIT_PREFIX/.legacy-app.XXXXXX") || return 1
  for item in vm-init.sh modules scripts VERSION vm-init.yml README.md LICENSE docs; do
    [[ -e "$VM_INIT_PREFIX/$item" ]] || continue
    cp -a "$VM_INIT_PREFIX/$item" "$stage/" || { rm -rf "$stage"; return 1; }
  done
  if ! install_app "$stage" vm-init.sh; then rm -rf "$stage"; return 1; fi
  link_legacy_app
}
