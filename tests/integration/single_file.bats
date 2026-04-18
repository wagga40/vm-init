#!/usr/bin/env bats
# Integration tests for the single-file bundle built by scripts/build-single.sh.
#
# Each test builds a fresh bundle into a per-test tempdir and then exercises
# its non-destructive entry points (--help, --version, --list-modules,
# --dry-run, --write-default-config). The bundle is invoked from an
# arbitrary working directory to confirm it does not rely on the repo
# layout at runtime.

setup() {
  load '../test_helper.bash'
  make_test_tmpdir
  export BUILD_SH="${VM_INIT_REPO_ROOT}/scripts/build-single.sh"
  export BUNDLE_DIR="$TEST_TMPDIR/out"

  # Build fresh. The script prints a banner on stdout; silence it to keep
  # test output readable on failure.
  run bash "$BUILD_SH" "$BUNDLE_DIR"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  # Locate the produced bundle. Version comes from the VERSION file.
  BUNDLES=( "$BUNDLE_DIR"/vm-init-* )
  # Exclude .sha256 sidecar files.
  for b in "${BUNDLES[@]}"; do
    if [[ "$b" != *.sha256 ]]; then
      export BUNDLE="$b"
      break
    fi
  done
  [ -n "${BUNDLE:-}" ] && [ -x "$BUNDLE" ]
}

teardown() {
  cleanup_test_tmpdir
}

# ---------- build artifact ----------

@test "build-single: emits a single executable script with a sha256 sidecar" {
  [ -f "$BUNDLE" ]
  [ -x "$BUNDLE" ]
  [ -f "${BUNDLE}.sha256" ]
  # Checksum file should reference the bundle's basename.
  grep -q "$(basename "$BUNDLE")" "${BUNDLE}.sha256"
}

@test "build-single: generated script passes bash -n" {
  run bash -n "$BUNDLE"
  [ "$status" -eq 0 ]
}

@test "build-single: bundle declares VM_INIT_BUNDLED and version" {
  grep -q '^export VM_INIT_BUNDLED=1$' "$BUNDLE"
  grep -q '^export VM_INIT_BUNDLED_VERSION=' "$BUNDLE"
}

@test "build-single: bundle embeds all 8 install_ entry functions" {
  for fn in install_apt install_ufw install_dns install_docker install_python \
            install_github_tools install_github_releases install_shell; do
    grep -q "^${fn}() {" "$BUNDLE" \
      || { echo "missing entry: $fn"; return 1; }
  done
}

@test "build-single: bundle embeds the default vm-init.yml verbatim" {
  embedded="$TEST_TMPDIR/embedded.yml"
  awk '
    /^_emit_default_config\(\) \{/ { in_fn=1; next }
    in_fn && /__VM_INIT_DEFAULT_YAML__/ {
      if (in_heredoc) { exit } else { in_heredoc=1; next }
    }
    in_heredoc { print }
  ' "$BUNDLE" > "$embedded"
  diff -q "$VM_INIT_DEFAULT_CONFIG" "$embedded"
}

# ---------- runtime behavior ----------

@test "bundle: --help exits 0 and lists all options including --write-default-config" {
  run "$BUNDLE" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--config"* ]]
  [[ "$output" == *"--list-modules"* ]]
  [[ "$output" == *"--dry-run"* ]]
  [[ "$output" == *"--write-default-config"* ]]
  [[ "$output" == *"Modules:"* ]]
}

@test "bundle: --version prints the baked-in version" {
  run "$BUNDLE" --version
  [ "$status" -eq 0 ]
  expected=$(tr -d '[:space:]' < "${VM_INIT_REPO_ROOT}/VERSION")
  [[ "$output" == "vm-init ${expected}" ]]
}

@test "bundle: --list-modules works without --config using embedded default" {
  if ! command -v yq >/dev/null 2>&1; then
    skip "yq v4 (mikefarah) not installed"
  fi
  # Invoke from an unrelated directory with no vm-init.yml alongside.
  cd "$TEST_TMPDIR"
  run "$BUNDLE" --list-modules
  [ "$status" -eq 0 ]
  for mod in apt ufw dns docker python github_tools github_releases shell; do
    [[ "$output" == *"$mod"* ]] || { echo "missing: $mod"; echo "$output"; return 1; }
  done
}

@test "bundle: --dry-run works without --config using embedded default" {
  if ! command -v yq >/dev/null 2>&1; then
    skip "yq v4 (mikefarah) not installed"
  fi
  cd "$TEST_TMPDIR"
  run "$BUNDLE" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]
  [[ "$output" == *"Dry run complete"* ]]
  [[ "$output" == *"ok: 8"* ]]
}

@test "bundle: explicit --config overrides embedded default" {
  if ! command -v yq >/dev/null 2>&1; then
    skip "yq v4 (mikefarah) not installed"
  fi
  # Build a config where only dns is enabled. The embedded default has all
  # 8 modules enabled, so we'd see a very different ok/skipped count.
  user_cfg="$TEST_TMPDIR/only-dns.yml"
  cat > "$user_cfg" <<'YAML'
apt: {enabled: false}
ufw: {enabled: false}
dns: {enabled: true, server: "https://base.dns.mullvad.net/dns-query", listen_port: 5353}
docker: {enabled: false}
python: {enabled: false}
github_tools: {enabled: false}
github_releases: {enabled: false}
shell: {enabled: false}
YAML
  cd "$TEST_TMPDIR"
  run "$BUNDLE" --dry-run --config "$user_cfg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok: 1"* ]]
  [[ "$output" == *"skipped: 7"* ]]
}

@test "bundle: explicit --config with missing file errors (no silent fallback)" {
  run "$BUNDLE" --dry-run --config /nonexistent/vm-init.yml
  [ "$status" -eq 1 ]
  [[ "$output" == *"Config file not found"* ]]
  [[ "$output" == *"/nonexistent/vm-init.yml"* ]]
}

@test "bundle: --write-default-config writes ./vm-init.yml in the current directory" {
  workdir="$TEST_TMPDIR/writecfg"
  mkdir -p "$workdir"
  cd "$workdir"
  run "$BUNDLE" --write-default-config
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wrote default config to"* ]]
  [[ "$output" == *"${workdir}/vm-init.yml"* ]]
  [ -f "${workdir}/vm-init.yml" ]
  # Byte-identical to the repo default.
  diff -q "$VM_INIT_DEFAULT_CONFIG" "${workdir}/vm-init.yml"
}

@test "bundle: --write-default-config refuses to clobber an existing file" {
  workdir="$TEST_TMPDIR/writecfg2"
  mkdir -p "$workdir"
  echo "# pre-existing" > "${workdir}/vm-init.yml"
  cd "$workdir"
  run "$BUNDLE" --write-default-config
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
  # Original content is untouched.
  grep -q '^# pre-existing$' "${workdir}/vm-init.yml"
}

@test "bundle: --write-default-config fails cleanly when cwd is not writable" {
  if [[ $EUID -eq 0 ]]; then
    skip "root ignores filesystem permissions"
  fi
  workdir="$TEST_TMPDIR/ro"
  mkdir -p "$workdir"
  chmod 555 "$workdir"
  cd "$workdir"
  run "$BUNDLE" --write-default-config
  # Restore so teardown can rm -rf.
  chmod 755 "$workdir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not write"* ]]
  [ ! -f "${workdir}/vm-init.yml" ]
}

@test "bundle: config written by --write-default-config drives a valid --dry-run" {
  if ! command -v yq >/dev/null 2>&1; then
    skip "yq v4 (mikefarah) not installed"
  fi
  workdir="$TEST_TMPDIR/writecfg3"
  mkdir -p "$workdir"
  cd "$workdir"
  run "$BUNDLE" --write-default-config
  [ "$status" -eq 0 ]
  run "$BUNDLE" --dry-run --config "${workdir}/vm-init.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok: 8"* ]]
}

@test "bundle: --only unknown errors with clear message" {
  run "$BUNDLE" --dry-run --only bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown module"* ]]
  [[ "$output" == *"bogus"* ]]
}

# ---------- invariant: no reference to runtime source files ----------

@test "bundle: does not source modules/*.sh at runtime (fails if modules/ absent)" {
  # Copy only the bundle into an empty dir with NO modules/ directory.
  empty_dir="$TEST_TMPDIR/standalone"
  mkdir -p "$empty_dir"
  cp "$BUNDLE" "$empty_dir/vm-init"

  if ! command -v yq >/dev/null 2>&1; then
    skip "yq v4 (mikefarah) not installed"
  fi

  cd "$empty_dir"
  run ./vm-init --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"ok: 8"* ]]
}
