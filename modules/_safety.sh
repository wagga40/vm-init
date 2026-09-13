#!/usr/bin/env bash
# Transactions only receive application-owned paths from their callers.

snapshot_paths() {
  local snapshot="$1" path
  shift
  mkdir -p "$snapshot/files" || return 1
  chmod 700 "$snapshot"
  : > "$snapshot/paths"
  for path in "$@"; do
    [[ "$path" == /* && "$path" != / && "$path" != *$'\n'* ]] || return 1
    if [[ -e "$path" || -L "$path" ]]; then
      mkdir -p "$snapshot/files$(dirname "$path")" || return 1
      cp -a "$path" "$snapshot/files$path" || return 1
      printf 'present %s\n' "$path" >> "$snapshot/paths"
    else
      printf 'absent %s\n' "$path" >> "$snapshot/paths"
    fi
  done
}

restore_paths() {
  local snapshot="$1" state path rc=0
  [[ -f "$snapshot/paths" ]] || return 1
  while read -r state path; do
    [[ "$path" == /* && "$path" != / ]] || return 1
    rm -rf -- "$path" || { rc=1; continue; }
    if [[ "$state" == present ]]; then
      mkdir -p "$(dirname "$path")" || { rc=1; continue; }
      cp -a "$snapshot/files$path" "$path" || rc=1
    fi
  done < "$snapshot/paths"
  return "$rc"
}

acquire_run_lock() {
  require_commands flock || return 1
  # A managed update invokes the installer and preparation in child shells.
  # They inherit the same open file description, rather than locking twice.
  if [[ -n "${VM_INIT_LOCK_FD:-}" ]] && flock -n "$VM_INIT_LOCK_FD" 2>/dev/null; then return 0; fi
  mkdir -p "$VM_INIT_STATE_DIR" || return 1
  exec {VM_INIT_LOCK_FD}>"$VM_INIT_STATE_DIR/run.lock"
  if ! flock -n "$VM_INIT_LOCK_FD"; then
    log_fail "Another vm-init change is running. Wait for it to finish, then retry."
    return 1
  fi
  export VM_INIT_LOCK_FD
}

# Explicitly run a child without the parent's mutation lock. Used only for a
# delayed rollback; the timer must not keep the lock after vm-init exits.
without_run_lock() (
  if [[ -n "${VM_INIT_LOCK_FD:-}" ]]; then exec {VM_INIT_LOCK_FD}>&-; fi
  exec "$@"
)
