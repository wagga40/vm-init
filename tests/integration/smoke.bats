#!/usr/bin/env bats
# Integration smoke tests for vm-init.sh.
#
# These tests exercise the orchestrator's non-destructive code paths:
# --help, --version, --list-modules, --dry-run, --only/--skip, config validation.
# They require yq v4 (mikefarah) on PATH.

setup() {
  load '../test_helper.bash'
  make_test_tmpdir
  export CONFIG="$TEST_TMPDIR/vm-init.yml"
  make_minimal_config "$CONFIG"
}

teardown() {
  cleanup_test_tmpdir
}

# ---------- help, version, unknown flag ----------

@test "--help exits 0 and mentions all CLI flags" {
  run "$VM_INIT_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--config"* ]]
  [[ "$output" == *"--only"* ]]
  [[ "$output" == *"--skip"* ]]
  [[ "$output" == *"--dry-run"* ]]
  [[ "$output" == *"--list-modules"* ]]
  [[ "$output" == *"--list-modules, -l"* ]]
  [[ "$output" == *"--update"* ]]
  [[ "$output" == *"--update, -u"* ]]
  [[ "$output" == *"--write-default-config"* ]]
  [[ "$output" == *"--write-default-config, -w"* ]]
  [[ "$output" == *"--force"* ]]
  [[ "$output" == *"--force, -f"* ]]
  [[ "$output" == *"--config, -c"* ]]
  [[ "$output" == *"--verbose"* ]]
  [[ "$output" == *"--no-log"* ]]
  [[ "$output" == *"Examples:"* ]]
}

@test "--update in local checkout mode prints guidance and download link" {
  run "$VM_INIT_SH" --update
  [ "$status" -eq 0 ]
  [[ "$output" == *"local checkout mode"* ]]
  [[ "$output" == *"https://github.com/wagga40/vm-init/releases/latest/download/vm-init"* ]]
}

@test "-u is an alias for --update" {
  run "$VM_INIT_SH" -u
  [ "$status" -eq 0 ]
  [[ "$output" == *"local checkout mode"* ]]
}

@test "--update in installed mode passes a v-prefixed tag to installer" {
  if [[ "$EUID" -ne 0 ]]; then
    skip "requires root to exercise installed-mode update path"
  fi
  if [[ ! -d /opt ]] || [[ ! -w /opt ]]; then
    skip "/opt is not writable in this environment"
  fi

  test_root="/opt/vm-init/ci-update-test-$$"
  capture_args="$TEST_TMPDIR/update-installer-args.txt"
  capture_env="$TEST_TMPDIR/update-installer-env.txt"
  mkdir -p "$test_root/scripts" "$test_root/modules"
  trap 'rm -rf "$test_root"' RETURN

  cp "$VM_INIT_SH" "$test_root/vm-init.sh"
  cp "$VM_INIT_COMMON_SH" "$test_root/modules/_common.sh"
  cp "$VM_INIT_DEFAULT_CONFIG" "$test_root/vm-init.yml"
  cp "$VM_INIT_REPO_ROOT/VERSION" "$test_root/VERSION"

  cat > "$test_root/scripts/install.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$CAPTURE_ARGS"
if [[ "${VM_INIT_VERSION+x}" == "x" ]]; then
  printf '%s\n' "$VM_INIT_VERSION" > "$CAPTURE_ENV"
else
  printf '%s\n' "__UNSET__" > "$CAPTURE_ENV"
fi
SH
  chmod +x "$test_root/scripts/install.sh"

  CAPTURE_ARGS="$capture_args" \
  CAPTURE_ENV="$capture_env" \
  VM_INIT_UPDATE_LATEST_OVERRIDE="v9.9.9" \
  run "$test_root/vm-init.sh" --update

  [ "$status" -eq 0 ]
  [[ "$output" == *"Updating vm-init installation under /opt/vm-init"* ]]
  [[ "$output" == *"Latest available release: 9.9.9"* ]]

  grep -q -- '--prefix /opt/vm-init' "$capture_args"
  grep -q -- '--version v9.9.9' "$capture_args"
  grep -q '^__UNSET__$' "$capture_env"
}

@test "-h is an alias for --help" {
  run "$VM_INIT_SH" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"vm-init"* ]]
}

@test "--version prints vm-init and version" {
  run "$VM_INIT_SH" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "vm-init "* ]]
}

@test "--version skips update check notice" {
  VM_INIT_UPDATE_LATEST_OVERRIDE="9.9.9" run "$VM_INIT_SH" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "vm-init "* ]]
  [[ "$output" != *"New vm-init version available"* ]]
}

@test "unknown flag exits 1 with usage" {
  run "$VM_INIT_SH" --nonexistent-flag
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option"* ]]
  [[ "$output" == *"Usage:"* ]]
}

# ---------- --write-default-config (repo layout) ----------

@test "--write-default-config writes ./vm-init.yml in the current directory" {
  workdir="$TEST_TMPDIR/writecfg"
  mkdir -p "$workdir"
  cd "$workdir"
  run "$VM_INIT_SH" --write-default-config
  [ "$status" -eq 0 ]
  [[ "$output" == *"Wrote default config to"* ]]
  [[ "$output" == *"${workdir}/vm-init.yml"* ]]
  [ -f "${workdir}/vm-init.yml" ]
  diff -q "$VM_INIT_DEFAULT_CONFIG" "${workdir}/vm-init.yml"
}

@test "--write-default-config refuses to clobber an existing file" {
  workdir="$TEST_TMPDIR/writecfg2"
  mkdir -p "$workdir"
  echo "# pre-existing" > "${workdir}/vm-init.yml"
  cd "$workdir"
  run "$VM_INIT_SH" --write-default-config
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
  grep -q '^# pre-existing$' "${workdir}/vm-init.yml"
}

@test "-w is an alias for --write-default-config" {
  workdir="$TEST_TMPDIR/writecfg3"
  mkdir -p "$workdir"
  cd "$workdir"
  run "$VM_INIT_SH" -w
  [ "$status" -eq 0 ]
  [ -f "${workdir}/vm-init.yml" ]
}

# ---------- --list-modules ----------

@test "--list-modules prints all 8 modules" {
  run "$VM_INIT_SH" --list-modules --config "$CONFIG"
  [ "$status" -eq 0 ]
  for mod in apt ufw dns docker python github_tools github_releases shell; do
    [[ "$output" == *"$mod"* ]] || { echo "missing: $mod"; echo "$output"; return 1; }
  done
}

@test "-l and -c are aliases for --list-modules and --config" {
  run "$VM_INIT_SH" -l -c "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Modules"* ]]
}

@test "--list-modules marks disabled modules as off" {
  mixed_config="$TEST_TMPDIR/mixed.yml"
  make_mixed_config "$mixed_config"
  run "$VM_INIT_SH" --list-modules --config "$mixed_config"
  [ "$status" -eq 0 ]
  [[ "$output" == *"off"* ]]
  [[ "$output" == *"docker"* ]]
}

# ---------- --dry-run ----------

@test "--dry-run exits 0 and makes no changes" {
  run "$VM_INIT_SH" --dry-run --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY RUN"* ]]
  [[ "$output" == *"Dry run complete"* ]]
  [[ "$output" == *"Summary"* ]]
}

@test "-f is an alias for --force" {
  run "$VM_INIT_SH" -f --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--force, -f"* ]]
}

@test "--dry-run prints update notice when newer release is known" {
  VM_INIT_UPDATE_LATEST_OVERRIDE="9.9.9" run "$VM_INIT_SH" --dry-run --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"New vm-init version available"* ]]
  [[ "$output" == *"Current:"* ]]
  [[ "$output" == *"Latest:"* ]]
  [[ "$output" == *"https://github.com/wagga40/vm-init/releases/latest/download/vm-init"* ]]
}

@test "--list-modules skips update check notice" {
  VM_INIT_UPDATE_LATEST_OVERRIDE="9.9.9" run "$VM_INIT_SH" --list-modules --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" != *"New vm-init version available"* ]]
}

@test "--dry-run auto-picks ./vm-init.yml before the shipped default" {
  if [[ -f /etc/vm-init/vm-init.yml ]]; then
    skip "/etc/vm-init/vm-init.yml exists and has higher precedence"
  fi

  workdir="$TEST_TMPDIR/cwd-config"
  mkdir -p "$workdir"
  cwd_config="${workdir}/vm-init.yml"
  cat > "$cwd_config" <<'YAML'
apt: {enabled: false}
ufw: {enabled: false}
dns: {enabled: true, server: "https://base.dns.mullvad.net/dns-query", listen_port: 5353}
docker: {enabled: false}
python: {enabled: false}
github_tools: {enabled: false}
github_releases: {enabled: false}
shell: {enabled: false}
YAML

  cd "$workdir"
  run "$VM_INIT_SH" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok: 1"* ]]
  [[ "$output" == *"skipped: 7"* ]]
}

@test "--dry-run does not write to /var/log" {
  log_count_before=$(find /var/log -maxdepth 1 -name 'vm-init-*.log' 2>/dev/null | wc -l || echo 0)
  "$VM_INIT_SH" --dry-run --config "$CONFIG" >/dev/null 2>&1
  log_count_after=$(find /var/log -maxdepth 1 -name 'vm-init-*.log' 2>/dev/null | wc -l || echo 0)
  [ "$log_count_before" = "$log_count_after" ]
}

# ---------- --only / --skip ----------

@test "--only filters to a single module" {
  run "$VM_INIT_SH" --dry-run --only dns --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok: 1"* ]]
  [[ "$output" == *"skipped: 7"* ]]
}

@test "--skip excludes modules" {
  run "$VM_INIT_SH" --dry-run --skip docker,github_releases --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped: 2"* ]]
}

@test "--only unknown-module exits 1 with clear error" {
  run "$VM_INIT_SH" --dry-run --only bogus --config "$CONFIG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown module"* ]]
  [[ "$output" == *"bogus"* ]]
}

@test "--only accepts comma-separated list" {
  run "$VM_INIT_SH" --dry-run --only apt,dns --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok: 2"* ]]
  [[ "$output" == *"skipped: 6"* ]]
}

# ---------- config validation ----------

@test "config validation: rejects missing dns.server scheme" {
  bad_config="$TEST_TMPDIR/bad.yml"
  cat > "$bad_config" <<'YAML'
dns:
  enabled: true
  server: "example.com/dns"  # missing https:// / tls:// scheme
  listen_port: 5353
ufw:
  enabled: false
github_releases:
  enabled: false
shell:
  enabled: false
YAML
  run "$VM_INIT_SH" --dry-run --config "$bad_config"
  [ "$status" -eq 1 ]
  [[ "$output" == *"dns.server must start with"* ]]
}

@test "config validation: rejects invalid ufw default" {
  bad_config="$TEST_TMPDIR/bad.yml"
  cat > "$bad_config" <<'YAML'
dns:
  enabled: false
ufw:
  enabled: true
  defaults:
    incoming: banana
    outgoing: allow
  allow: []
github_releases:
  enabled: false
shell:
  enabled: false
YAML
  run "$VM_INIT_SH" --dry-run --config "$bad_config"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ufw.defaults.incoming must be"* ]]
}

@test "config validation: rejects invalid listen_port" {
  bad_config="$TEST_TMPDIR/bad.yml"
  cat > "$bad_config" <<'YAML'
dns:
  enabled: true
  server: https://example.com/dns-query
  listen_port: 99999  # > 65535
ufw:
  enabled: false
github_releases:
  enabled: false
shell:
  enabled: false
YAML
  run "$VM_INIT_SH" --dry-run --config "$bad_config"
  [ "$status" -eq 1 ]
  [[ "$output" == *"dns.listen_port"* ]]
}

@test "config validation: passes on minimal valid config" {
  run "$VM_INIT_SH" --dry-run --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Config valid"* ]]
}

@test "config validation: missing config file exits 1" {
  run "$VM_INIT_SH" --dry-run --config /nonexistent/path/to/config.yml
  [ "$status" -eq 1 ]
  [[ "$output" == *"Config file not found"* ]]
}

# ---------- packaging round-trip ----------

@test "task package produces a versioned tarball with valid sha256" {
  if ! command -v task >/dev/null 2>&1; then
    skip "task binary not installed"
  fi
  cd "$VM_INIT_REPO_ROOT"
  # Isolated DIST_DIR so we don't stomp whatever the user may have there.
  # Newer task versions honor CLI var overrides; older ones ignore them and
  # fall back to the Taskfile default of ./dist — search both locations.
  dist="$TEST_TMPDIR/dist"
  mkdir -p "$dist"
  run task package DIST_DIR="$dist"
  [ "$status" -eq 0 ]

  tarball=""
  for candidate in "$dist"/vm-init-*.tar.gz "$VM_INIT_REPO_ROOT"/dist/vm-init-*.tar.gz; do
    if [[ -f "$candidate" ]]; then
      tarball="$candidate"
      break
    fi
  done
  [ -n "$tarball" ] || { echo "No tarball produced in $dist or $VM_INIT_REPO_ROOT/dist"; return 1; }
  [ -f "${tarball}.sha256" ]

  cd "$(dirname "$tarball")"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c "$(basename "$tarball").sha256"
  else
    shasum -a 256 -c "$(basename "$tarball").sha256"
  fi
}

@test "task build-single produces a versioned single-file with valid sha256" {
  if ! command -v task >/dev/null 2>&1; then
    skip "task binary not installed"
  fi
  cd "$VM_INIT_REPO_ROOT"
  dist="$TEST_TMPDIR/dist"
  mkdir -p "$dist"
  run task build-single DIST_DIR="$dist"
  [ "$status" -eq 0 ]

  bundle=""
  for candidate in "$dist"/vm-init-* "$VM_INIT_REPO_ROOT"/dist/vm-init-*; do
    [[ "$candidate" == *.sha256 ]] && continue
    [[ "$candidate" == *.tar.gz ]] && continue
    if [[ -f "$candidate" ]]; then
      bundle="$candidate"
      break
    fi
  done
  [ -n "$bundle" ] || { echo "No bundle produced in $dist or $VM_INIT_REPO_ROOT/dist"; return 1; }
  [ -x "$bundle" ]
  [ -f "${bundle}.sha256" ]

  bash -n "$bundle"

  cd "$(dirname "$bundle")"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c "$(basename "$bundle").sha256"
  else
    shasum -a 256 -c "$(basename "$bundle").sha256"
  fi
}
