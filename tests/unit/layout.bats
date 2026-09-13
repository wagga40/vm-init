#!/usr/bin/env bats

setup() {
  load '../test_helper.bash'
  make_test_tmpdir
  load_common
  export VM_INIT_LEGACY_ROOT="$TEST_TMPDIR/legacy"
  mkdir -p "$VM_INIT_LEGACY_ROOT/etc/vm-init" "$VM_INIT_LEGACY_ROOT/var/lib/vm-init/runs/old" "$VM_INIT_LEGACY_ROOT/var/log"
  echo 'users: [root]' > "$VM_INIT_LEGACY_ROOT/etc/vm-init/vm-init.yml"
  echo '{"users":["root"]}' > "$VM_INIT_LEGACY_ROOT/var/lib/vm-init/runs/old/config.json"
  printf 'last.config=%s/var/lib/vm-init/runs/old/config.json\n' "$VM_INIT_LEGACY_ROOT" > "$VM_INIT_LEGACY_ROOT/var/lib/vm-init/state"
  echo history > "$VM_INIT_LEGACY_ROOT/var/log/vm-init-old.log"
  unset VM_INIT_STATE_DIR VM_INIT_STATE_FILE
  init_layout
}

teardown() { cleanup_test_tmpdir; }

@test "read-only path initialization selects legacy state without creating the new layout" {
  [ "$VM_INIT_STATE_DIR" = "$VM_INIT_LEGACY_ROOT/var/lib/vm-init" ]
  [ ! -d "$VM_INIT_PREFIX" ]
  CONFIG_EXPLICIT=0 SCRIPT_DIR="$TEST_TMPDIR"
  select_config
  [ "$CONFIG" = "$VM_INIT_LEGACY_ROOT/etc/vm-init/vm-init.yml" ]
  [ ! -d "$VM_INIT_PREFIX" ]
}

@test "a legacy managed custom prefix can discover the old shared system paths" {
  unset VM_INIT_LEGACY_ROOT
  run uses_legacy_layout
  [ "$status" -ne 0 ]
  mkdir -p "$VM_INIT_PREFIX"
  printf '%s\n0\n' "$VM_INIT_BIN_DIR" > "$VM_INIT_PREFIX/.vm-init-managed"
  uses_legacy_layout
}

@test "migration preserves retry paths logs and the held mutation lock" {
  command -v flock >/dev/null || skip 'requires Linux flock'
  acquire_run_lock
  migrate_layout
  [ -L "$VM_INIT_LEGACY_ROOT/var/lib/vm-init" ]
  [ -L "$VM_INIT_LEGACY_ROOT/etc/vm-init" ]
  [ -L "$VM_INIT_LEGACY_ROOT/var/log/vm-init-old.log" ]
  [ -f "$(state_get last.config)" ]
  [ "$(cat "$VM_INIT_PREFIX/logs/vm-init-old.log")" = history ]
  run flock -n "$VM_INIT_PREFIX/state/run.lock" true
  [ "$status" -ne 0 ]
  # Migration must release its firewall lock before applying modules.
  run flock -n "$VM_INIT_PREFIX/state/firewall.lock" true
  [ "$status" -eq 0 ]
}

@test "migration rejects conflicting configuration before moving state or logs" {
  command -v flock >/dev/null || skip 'requires Linux flock'
  mkdir -p "$VM_INIT_PREFIX/config"
  echo new > "$VM_INIT_PREFIX/config/vm-init.yml"
  acquire_run_lock
  run migrate_layout
  [ "$status" -ne 0 ]
  [[ "$output" == *'conflicting paths'* ]]
  [ ! -L "$VM_INIT_LEGACY_ROOT/var/lib/vm-init" ]
  [ ! -d "$VM_INIT_PREFIX/state" ]
  [ "$(cat "$VM_INIT_PREFIX/config/vm-init.yml")" = new ]
}

@test "migration defers while legacy firewall confirmation is pending" {
  command -v flock >/dev/null || skip 'requires Linux flock'
  echo pending > "$VM_INIT_STATE_DIR/firewall-pending"
  acquire_run_lock
  run migrate_layout
  [ "$status" -ne 0 ]
  [[ "$output" == *'pending firewall'* ]]
  [ ! -d "$VM_INIT_PREFIX/state" ]
  [ ! -L "$VM_INIT_STATE_DIR" ]
}

@test "migration is idempotent and preserves later writes through compatibility paths" {
  command -v flock >/dev/null || skip 'requires Linux flock'
  acquire_run_lock
  migrate_layout
  echo later >> "$VM_INIT_LEGACY_ROOT/var/lib/vm-init/state"
  migrate_layout
  [ "$(tail -n 1 "$VM_INIT_PREFIX/state/state")" = later ]
  [ -f "$VM_INIT_PREFIX/config/vm-init.yml" ]
}

@test "migration keeps the new run lock held across different filesystems" {
  [[ -d /dev/shm && -w /dev/shm ]] || skip 'requires writable Linux tmpfs'
  command -v flock >/dev/null || skip 'requires Linux flock'
  local alternate
  alternate=$(mktemp -d /dev/shm/vm-init-test.XXXXXX)
  VM_INIT_PREFIX="$alternate/installation"
  unset VM_INIT_STATE_DIR VM_INIT_STATE_FILE
  init_layout
  acquire_run_lock
  migrate_layout
  [ -f "$(state_get last.config)" ]
  run flock -n "$VM_INIT_PREFIX/state/run.lock" true
  [ "$status" -ne 0 ]
  rm -rf "$alternate"
}
