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
  cp "$VM_INIT_SH" "$VM_INIT_REPO_ROOT/VERSION" "$VM_INIT_REPO_ROOT/vm-init.yml" "$TEST_TMPDIR/release/"
  cp -R "$VM_INIT_REPO_ROOT/modules/." "$TEST_TMPDIR/release/modules/"
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

@test "installer installs code without requiring a separate preparation and preserves readable permissions" {
  run bash "$VM_INIT_REPO_ROOT/scripts/install.sh" --no-symlink
  [ "$status" -eq 0 ]
  [ ! -d "$VM_INIT_STATE_DIR/runs" ]
  [ -f "$VM_INIT_PREFIX/app/vm-init.sh" ]
  [ -x "$VM_INIT_PREFIX/bin/vm-init" ]
  [ "$(stat -c %a "$VM_INIT_PREFIX")" = 755 ]
  [ "$(stat -c %a "$VM_INIT_PREFIX/app/vm-init.sh")" = 755 ]
}

@test "installer keeps the old installation when the release fails syntax validation" {
  mkdir -p "$VM_INIT_PREFIX"
  echo old-installation > "$VM_INIT_PREFIX/vm-init.sh"
  echo 'if invalid syntax' > "$TEST_TMPDIR/release/vm-init.sh"
  tar czf "$TEST_TMPDIR/downloads/vm-init.tar.gz" -C "$TEST_TMPDIR" release
  (cd "$TEST_TMPDIR/downloads" && sha256sum vm-init.tar.gz > vm-init.tar.gz.sha256)
  run bash "$VM_INIT_REPO_ROOT/scripts/install.sh" --no-symlink
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

@test "a second installation preserves configuration state and logs" {
  run bash "$VM_INIT_REPO_ROOT/scripts/install.sh"
  [ "$status" -eq 0 ]
  mkdir -p "$VM_INIT_PREFIX/config" "$VM_INIT_PREFIX/logs" "$VM_INIT_STATE_DIR/runs/saved"
  echo 'users: [root]' > "$VM_INIT_PREFIX/config/vm-init.yml"
  echo baseline > "$VM_INIT_STATE_DIR/runs/saved/config.json"
  echo log > "$VM_INIT_PREFIX/logs/old.log"
  run bash "$VM_INIT_REPO_ROOT/scripts/install.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$VM_INIT_PREFIX/config/vm-init.yml")" = 'users: [root]' ]
  [ "$(cat "$VM_INIT_STATE_DIR/runs/saved/config.json")" = baseline ]
  [ "$(cat "$VM_INIT_PREFIX/logs/old.log")" = log ]
  [ -x "$VM_INIT_BIN_DIR/vm-init" ]
}

@test "failed command creation restores the previous managed application and entry point" {
  run bash "$VM_INIT_REPO_ROOT/scripts/install.sh" --no-symlink
  [ "$status" -eq 0 ]
  echo previous > "$VM_INIT_PREFIX/app/previous"
  before=$(readlink "$VM_INIT_PREFIX/bin/vm-init")
  touch "$VM_INIT_BIN_DIR"
  run bash "$VM_INIT_REPO_ROOT/scripts/install.sh"
  [ "$status" -ne 0 ]
  [ "$(cat "$VM_INIT_PREFIX/app/previous")" = previous ]
  [ "$(readlink "$VM_INIT_PREFIX/bin/vm-init")" = "$before" ]
}

@test "installer rejects a checksum mismatch before changing an existing application" {
  mkdir -p "$VM_INIT_PREFIX"
  echo old > "$VM_INIT_PREFIX/vm-init.sh"
  printf corrupt >> "$TEST_TMPDIR/downloads/vm-init.tar.gz"
  run bash "$VM_INIT_REPO_ROOT/scripts/install.sh"
  [ "$status" -ne 0 ]
  [ "$(cat "$VM_INIT_PREFIX/vm-init.sh")" = old ]
  [ ! -d "$VM_INIT_PREFIX/app" ]
}

@test "using the internal bin directory as the command directory never creates a circular link" {
  export VM_INIT_BIN_DIR="$VM_INIT_PREFIX/bin"
  run bash "$VM_INIT_REPO_ROOT/scripts/install.sh"
  [ "$status" -eq 0 ]
  [ -x "$VM_INIT_BIN_DIR/vm-init" ]
  run "$VM_INIT_BIN_DIR/vm-init" --version
  [ "$status" -eq 0 ]
}

@test "the old installer prepare-and-replace flow preserves custom configuration at a custom prefix" {
  export VM_INIT_LEGACY_ROOT="$TEST_TMPDIR/legacy" VM_INIT_MIN_DISK_MB=0
  mkdir -p "$VM_INIT_PREFIX"
  echo '#!/usr/bin/env bash' > "$VM_INIT_PREFIX/vm-init.sh"
  echo 1.10.1 > "$VM_INIT_PREFIX/VERSION"
  printf 'users: [root]\napt: {enabled: false}\nshell: {enabled: false}\n' > "$VM_INIT_PREFIX/vm-init.yml"
  cp "$VM_INIT_PREFIX/vm-init.yml" "$TEST_TMPDIR/expected.yml"
  stage="$TEST_TMPDIR/.vm-init.stage.test"
  cp -a "$TEST_TMPDIR/release" "$stage"
  # Older installers pass --prefix in argv, but do not export it to prepare.
  run env -u VM_INIT_PREFIX bash -c 'bash "$1/vm-init.sh" prepare; result=$?; exit "$result"' _ "$stage" --prefix "$VM_INIT_PREFIX"
  [ "$status" -eq 0 ]
  [ ! -d "$VM_INIT_PREFIX/config" ]
  cmp "$VM_INIT_STATE_DIR/legacy-install-config/config.yml" "$TEST_TMPDIR/expected.yml"
  # Match the old installer replacing its whole prefix after preparation.
  rm -rf "$VM_INIT_PREFIX"
  mv "$stage" "$VM_INIT_PREFIX"
  chmod 0755 "$VM_INIT_PREFIX"
  printf '%s\n0\n' "$VM_INIT_BIN_DIR" > "$VM_INIT_PREFIX/.vm-init-managed"
  run "$VM_INIT_PREFIX/vm-init.sh" --no-log
  [ "$status" -eq 0 ]
  cmp "$VM_INIT_PREFIX/config/vm-init.yml" "$TEST_TMPDIR/expected.yml"
  [ -x "$VM_INIT_PREFIX/bin/vm-init" ]
}

@test "prepare leaves legacy system configuration and recovery paths in place" {
  export VM_INIT_LEGACY_ROOT="$TEST_TMPDIR/legacy"
  mkdir -p "$VM_INIT_LEGACY_ROOT/etc/vm-init" "$VM_INIT_LEGACY_ROOT/var/lib/vm-init"
  echo '{}' > "$VM_INIT_LEGACY_ROOT/etc/vm-init/vm-init.yml"
  echo snapshot > "$VM_INIT_LEGACY_ROOT/var/lib/vm-init/snapshot"
  run env -u VM_INIT_STATE_DIR -u VM_INIT_STATE_FILE "$VM_INIT_SH" prepare
  [ "$status" -eq 0 ]
  [ ! -L "$VM_INIT_LEGACY_ROOT/etc/vm-init" ]
  [ ! -L "$VM_INIT_LEGACY_ROOT/var/lib/vm-init" ]
  [ ! -e "$VM_INIT_PREFIX/config" ]
  [ "$(cat "$VM_INIT_LEGACY_ROOT/var/lib/vm-init/snapshot")" = snapshot ]
}
