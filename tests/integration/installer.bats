#!/usr/bin/env bats

setup() {
  load '../test_helper.bash'
  make_test_tmpdir
  if [[ "$EUID" != 0 || ! -f /etc/os-release ]]; then skip 'requires root on Ubuntu'; fi
  grep -qi ubuntu /etc/os-release || skip 'requires Ubuntu'
  export VM_INIT_STATE_DIR="$TEST_TMPDIR/state"
  export VM_INIT_PREFIX="$TEST_TMPDIR/installed"
  export VM_INIT_BIN_DIR="$TEST_TMPDIR/commands"
  mkdir -p "$TEST_TMPDIR/release/modules" "$TEST_TMPDIR/downloads" "$TEST_TMPDIR/bin"
  touch "$TEST_TMPDIR/release/modules/_common.sh" "$TEST_TMPDIR/release/modules/_config.sh"
  echo 1.9.0 > "$TEST_TMPDIR/release/VERSION"
  cat > "$TEST_TMPDIR/release/vm-init.sh" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == prepare ]]; then
  [[ "${FAIL_PREPARE:-0}" != 1 ]] || exit 1
  touch "$TEST_TMPDIR/prepared"
fi
SH
  tar czf "$TEST_TMPDIR/downloads/vm-init.tar.gz" -C "$TEST_TMPDIR" release
  (cd "$TEST_TMPDIR/downloads" && sha256sum vm-init.tar.gz > vm-init.tar.gz.sha256)
  cat > "$TEST_TMPDIR/bin/curl" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == https://* ]]; then source_file="${arg##*/}"; fi
done
while [[ "$1" != -o ]]; do shift; done
cp "$TEST_TMPDIR/downloads/$source_file" "$2"
SH
  chmod +x "$TEST_TMPDIR/bin/curl"
  export PATH="$TEST_TMPDIR/bin:$PATH"
}

teardown() { cleanup_test_tmpdir; }

@test "installer prepares before swapping and preserves readable directory permissions" {
  run bash "$VM_INIT_REPO_ROOT/scripts/install.sh" --no-symlink
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/prepared" ]
  [ -f "$VM_INIT_PREFIX/vm-init.sh" ]
  [ "$(stat -c %a "$VM_INIT_PREFIX")" = 755 ]
  [ "$(stat -c %a "$VM_INIT_PREFIX/vm-init.sh")" = 755 ]
}

@test "installer keeps the old installation when preparation fails" {
  mkdir -p "$VM_INIT_PREFIX"
  echo old-installation > "$VM_INIT_PREFIX/vm-init.sh"
  FAIL_PREPARE=1 run bash "$VM_INIT_REPO_ROOT/scripts/install.sh" --no-symlink
  [ "$status" -ne 0 ]
  [ "$(cat "$VM_INIT_PREFIX/vm-init.sh")" = old-installation ]
  [ ! -e "$TEST_TMPDIR/prepared" ]
}

@test "installer restores the old installation if creating commands fails" {
  mkdir -p "$VM_INIT_PREFIX"
  echo old-installation > "$VM_INIT_PREFIX/vm-init.sh"
  touch "$VM_INIT_BIN_DIR"
  run bash "$VM_INIT_REPO_ROOT/scripts/install.sh"
  [ "$status" -ne 0 ]
  [ "$(cat "$VM_INIT_PREFIX/vm-init.sh")" = old-installation ]
}

@test "managed update preserves custom prefix and command settings" {
  mkdir -p "$VM_INIT_PREFIX/scripts"
  cp "$VM_INIT_SH" "$VM_INIT_REPO_ROOT/VERSION" "$VM_INIT_PREFIX/"
  cp -R "$VM_INIT_REPO_ROOT/modules" "$VM_INIT_PREFIX/"
  printf '%s\n1\n' "$VM_INIT_BIN_DIR" > "$VM_INIT_PREFIX/.vm-init-managed"
  cat > "$VM_INIT_PREFIX/scripts/install.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" "$VM_INIT_BIN_DIR" "$VM_INIT_NO_SYMLINK" > "$TEST_TMPDIR/update-arguments"
SH
  run "$VM_INIT_PREFIX/vm-init.sh" update
  [ "$status" -eq 0 ]
  grep -qxF -- "$VM_INIT_PREFIX" "$TEST_TMPDIR/update-arguments"
  grep -qxF -- "$VM_INIT_BIN_DIR" "$TEST_TMPDIR/update-arguments"
  [ "$(tail -n 1 "$TEST_TMPDIR/update-arguments")" = 1 ]
}
