#!/usr/bin/env bats
# Unit tests for modules/_common.sh helpers.

setup() {
  load '../test_helper.bash'
  make_test_tmpdir
  load_common
}

teardown() {
  cleanup_test_tmpdir
}

# ---------- is_installed / should_force ----------

@test "is_installed: returns 0 for real binary" {
  is_installed bash
}

@test "is_installed: returns non-zero for missing binary" {
  run is_installed "very-unlikely-binary-$$"
  [ "$status" -ne 0 ]
}

@test "require_commands: reports missing commands clearly" {
  run require_commands "very-unlikely-binary-$$"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Missing required command(s)"* ]]
  [[ "$output" == *"very-unlikely-binary-$$"* ]]
}

@test "should_force: false by default" {
  unset VM_INIT_FORCE || true
  run should_force
  [ "$status" -ne 0 ]
}

@test "should_force: true when VM_INIT_FORCE=1" {
  VM_INIT_FORCE=1 should_force
}

# ---------- with_retries ----------

@test "with_retries: succeeds on first try" {
  VM_INIT_RETRY_DELAY=0 with_retries true
}

@test "with_retries: returns non-zero after all attempts fail" {
  run bash -c "source '$VM_INIT_COMMON_SH'; VM_INIT_RETRIES=3 VM_INIT_RETRY_DELAY=0 with_retries false"
  [ "$status" -ne 0 ]
}

@test "with_retries: stops after first successful attempt" {
  marker="$TEST_TMPDIR/retry-marker"
  echo 0 > "$marker"
  flaky() {
    local n
    n=$(cat "$marker")
    n=$((n + 1))
    echo "$n" > "$marker"
    # Fail twice, then succeed on attempt 3
    [[ "$n" -ge 3 ]]
  }
  export -f flaky
  VM_INIT_RETRIES=5 VM_INIT_RETRY_DELAY=0 with_retries bash -c '
    source "'"$VM_INIT_COMMON_SH"'"
    n=$(cat "'"$marker"'")
    n=$((n + 1))
    echo "$n" > "'"$marker"'"
    [[ "$n" -ge 3 ]]
  '
  result=$(cat "$marker")
  [ "$result" = "3" ]
}

@test "run_with_errexit: stops wrapped module at first failing command" {
  run bash -c '
    source "$1"
    failing_module() {
      echo before
      run_quiet false
      echo after
    }
    set +e
    run_with_errexit failing_module
    rc=$?
    set -e
    printf "rc=%s\n" "$rc"
  ' _ "$VM_INIT_COMMON_SH"

  [ "$status" -eq 0 ]
  [[ "$output" == *"before"* ]]
  [[ "$output" != *"after"* ]]
  [[ "$output" == *"rc=1"* ]]
}

@test "run_with_errexit: propagates warning count from wrapped module" {
  run bash -c '
    source "$1"
    export VM_INIT_WARN_COUNT=0
    warning_module() {
      log_warn "test warning" >/dev/null
    }
    set +e
    run_with_errexit warning_module
    rc=$?
    set -e
    printf "rc=%s warnings=%s\n" "$rc" "$VM_INIT_WARN_COUNT"
  ' _ "$VM_INIT_COMMON_SH"

  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0 warnings=1"* ]]
}

@test "run_quiet: wraps external commands with timeout when available" {
  marker="$TEST_TMPDIR/timeout-args"
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/timeout" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$marker"
shift 2
"\$@"
EOF
  chmod +x "$TEST_TMPDIR/bin/timeout"
  old_path="$PATH"
  PATH="$TEST_TMPDIR/bin:$PATH"

  VM_INIT_CMD_TIMEOUT=7 run_quiet true

  PATH="$old_path"
  grep -q -- '--preserve-status 7 true' "$marker"
}

@test "run_quiet: does not wrap shell functions with timeout" {
  marker="$TEST_TMPDIR/function-called"
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/timeout" <<'EOF'
#!/usr/bin/env bash
exit 124
EOF
  chmod +x "$TEST_TMPDIR/bin/timeout"
  old_path="$PATH"
  PATH="$TEST_TMPDIR/bin:$PATH"
  sample_function() {
    echo called > "$marker"
  }

  VM_INIT_CMD_TIMEOUT=7 run_quiet sample_function

  PATH="$old_path"
  grep -q '^called$' "$marker"
}

# ---------- sha256 helpers ----------

@test "_sha256_of: computes known hash for 'hello'" {
  echo -n "hello" > "$TEST_TMPDIR/hello"
  hash=$(_sha256_of "$TEST_TMPDIR/hello")
  [ "$hash" = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" ]
}

@test "verify_sha256: succeeds with matching hash" {
  echo -n "hello" > "$TEST_TMPDIR/hello"
  verify_sha256 "$TEST_TMPDIR/hello" \
    "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
}

@test "verify_sha256: fails on mismatch (returns 1)" {
  echo -n "hello" > "$TEST_TMPDIR/hello"
  run verify_sha256 "$TEST_TMPDIR/hello" \
    "0000000000000000000000000000000000000000000000000000000000000000"
  [ "$status" -eq 1 ]
}

# ---------- logging side effects ----------

@test "log_warn: increments VM_INIT_WARN_COUNT" {
  export VM_INIT_WARN_COUNT=0
  log_warn "test warning" >/dev/null
  log_warn "another" >/dev/null
  [ "$VM_INIT_WARN_COUNT" = "2" ]
}

@test "log_ok: does not increment VM_INIT_WARN_COUNT" {
  export VM_INIT_WARN_COUNT=0
  log_ok "test" >/dev/null
  log_step "test" >/dev/null
  log_info "test" >/dev/null
  [ "$VM_INIT_WARN_COUNT" = "0" ]
}

# ---------- _github_auth_args ----------

@test "_github_auth_args: empty when no tokens set" {
  unset GH_TOKEN GITHUB_TOKEN || true
  run _github_auth_args
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_github_auth_args: uses GH_TOKEN when set" {
  unset GITHUB_TOKEN || true
  GH_TOKEN=abc123 run _github_auth_args
  [[ "$output" == *"Authorization: Bearer abc123"* ]]
}

@test "_github_auth_args: falls back to GITHUB_TOKEN" {
  unset GH_TOKEN || true
  GITHUB_TOKEN=xyz789 run _github_auth_args
  [[ "$output" == *"Authorization: Bearer xyz789"* ]]
}

# ---------- UI primitives ----------

@test "ui detection: color vars are empty when stdout is not a TTY" {
  # `run` captures output to a variable, so _common.sh saw a non-TTY stdout
  # when load_common ran in setup(). All color codes should be empty.
  [ -z "$_C_GREEN" ]
  [ -z "$_C_BOLD" ]
  [ -z "$_C_RESET" ]
}

@test "ui detection: status symbols are always set" {
  [ -n "$_SYM_OK" ]
  [ -n "$_SYM_WARN" ]
  [ -n "$_SYM_FAIL" ]
  [ -n "$_SYM_INFO" ]
  [ -n "$_SYM_SKIP" ]
  [ -n "$_SYM_ARROW" ]
}

@test "format_duration: under a minute" {
  result=$(format_duration 45)
  [ "$result" = "45s" ]
}

@test "format_duration: minutes and seconds" {
  result=$(format_duration 135)
  [ "$result" = "2m 15s" ]
}

@test "format_duration: hours, minutes, seconds" {
  result=$(format_duration 7325)
  [ "$result" = "2h 2m 5s" ]
}

@test "format_duration: zero seconds" {
  result=$(format_duration 0)
  [ "$result" = "0s" ]
}

@test "print_kv: prints label and value" {
  run print_kv "Config" "/etc/vm-init.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Config"* ]]
  [[ "$output" == *"/etc/vm-init.yml"* ]]
}

@test "print_rule: prints WIDTH rule chars" {
  result=$(print_rule 20)
  # Strip any (empty) escape sequences and count chars
  line_len=${#result}
  [ "$line_len" -ge 20 ]
}

@test "print_status_legend: mentions all status words" {
  run print_status_legend
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
  [[ "$output" == *"skip"* ]]
  [[ "$output" == *"warn"* ]]
  [[ "$output" == *"fail"* ]]
  [[ "$output" == *"info"* ]]
  [[ "$output" == *"step"* ]]
}

@test "log_section: accepts optional progress argument" {
  run log_section "apt" "1/9"
  [ "$status" -eq 0 ]
  [[ "$output" == *"apt"* ]]
  [[ "$output" == *"1/9"* ]]
}

@test "log_section: works with single argument (backward compat)" {
  run log_section "apt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"apt"* ]]
}

@test "log_done: prints success marker and message" {
  run log_done "Setup complete."
  [ "$status" -eq 0 ]
  [[ "$output" == *"Setup complete."* ]]
  [[ "$output" == *"${_SYM_OK}"* ]]
}

@test "dnsproxy_listening_on: fails closed when ss is unavailable" {
  # shellcheck source=/dev/null
  source "${VM_INIT_REPO_ROOT}/modules/dns.sh"
  old_path="$PATH"
  PATH="$TEST_TMPDIR/bin"

  run dnsproxy_listening_on 127.0.0.1 5353

  PATH="$old_path"
  [ "$status" -ne 0 ]
}

@test "install_dns: fails when requested dnsproxy installation fails" {
  # shellcheck source=/dev/null
  source "${VM_INIT_REPO_ROOT}/modules/dns.sh"
  require_commands() { return 0; }
  install_dnsproxy_binary() { return 1; }
  dns_prepare() { DNS_STAGE=$(mktemp -d); DNS_DESIRED=desired; DNS_OBSERVED=absent; RECONCILE_ACTION=apply; }
  export VM_INIT_STATE_DIR="$TEST_TMPDIR/state"
  dns_save_state() { return 0; }
  dns_restore_state() { return 0; }

  run install_dns

  [ "$status" -ne 0 ]
  [[ "$output" == *"DoH/DoT is NOT active"* ]]
}

@test "install_dns: preflights ss before changing DNS config" {
  # shellcheck source=/dev/null
  source "${VM_INIT_REPO_ROOT}/modules/dns.sh"
  marker="$TEST_TMPDIR/dns-preflight"
  require_commands() {
    printf '%s\n' "$*" > "$marker"
    return 1
  }

  run install_dns

  [ "$status" -ne 0 ]
  grep -q 'ss' "$marker"
}

@test "install_fisher_tide: returns non-zero when non-root fish setup fails" {
  # shellcheck source=/dev/null
  source "${VM_INIT_REPO_ROOT}/modules/shell.sh"
  run_as_user() { return 0; }
  yq_get() { echo true; }
  run_quiet() {
    if [[ "$1" == "download_file" ]]; then
      touch "$3"
      return 0
    fi
    return 1
  }

  chown() { return 0; }
  id() { echo staff; }
  run install_fisher_tide alice "$TEST_TMPDIR/home"

  [ "$status" -ne 0 ]
}

@test "run_fish_as: runs fish from a directory the target user can open" {
  # shellcheck source=/dev/null
  source "${VM_INIT_REPO_ROOT}/modules/shell.sh"
  captured="$TEST_TMPDIR/captured"
  run_quiet() { printf '%s\n' "$*" > "$captured"; }

  run_fish_as alice 'fisher update'

  grep -q 'sudo -u alice' "$captured"
  grep -q 'cd /' "$captured"
  grep -q 'fisher update' "$captured"
}

@test "setup_fisher_for: installs when the account has no fisher" {
  # shellcheck source=/dev/null
  source "${VM_INIT_REPO_ROOT}/modules/shell.sh"
  fisher_present_for() { return 1; }
  install_fisher_tide() { echo "installed-for:$1"; }
  run_fish_as() { echo "ran:$2"; }

  run setup_fisher_for alice "$TEST_TMPDIR/home"

  [ "$status" -eq 0 ]
  [[ "$output" == *"installed-for:alice"* ]]
  [[ "$output" != *"ran:fisher update"* ]]
}

@test "setup_fisher_for: updates when the account already has fisher" {
  # shellcheck source=/dev/null
  source "${VM_INIT_REPO_ROOT}/modules/shell.sh"
  fisher_present_for() { return 0; }
  install_fisher_tide() { echo "installed-for:$1"; }
  run_fish_as() { echo "ran:$2"; }

  run setup_fisher_for alice "$TEST_TMPDIR/home"

  [ "$status" -eq 0 ]
  [[ "$output" == *"ran:fisher update"* ]]
  [[ "$output" != *"installed-for:alice"* ]]
}

mock_shell_install() {
  export CONFIG="$TEST_TMPDIR/shell.yml"
  export VM_INIT_SHELL_PATH=/usr/bin/env
  export VM_INIT_TARGET_USERS='root alice bob'
  printf 'shell: {default_shell: fish, fisher: true, tide: false, aliases: {}}\n' > "$CONFIG"
  require_commands() { return 0; }
  shell_required_packages() { echo fish; }
  render_shell_config() { echo '# managed'; }
  run_as_user() { return 0; }
  target_users() { printf 'root:%s\nalice:%s\nbob:%s\n' "$TEST_TMPDIR/root" "$TEST_TMPDIR/alice" "$TEST_TMPDIR/bob"; }
  fish() { return 0; }
  install() { return 0; }
  chown() { return 0; }
  getent() {
    local account="$2" login=/bin/bash
    if [[ -f "$TEST_TMPDIR/$account.shell" ]]; then login=$(cat "$TEST_TMPDIR/$account.shell"); fi
    printf '%s:x:1000:1000::%s/%s:%s\n' "$account" "$TEST_TMPDIR" "$account" "$login"
  }
  write_shell_file() { mkdir -p "$(dirname "$2")"; cat > "$2"; }
  chsh() { printf '%s\n' "$2" > "$TEST_TMPDIR/$3.shell"; }
  id() { echo staff; }
  run_quiet() { return 0; }
}

@test "install_shell: a fish command cannot swallow the remaining user list" {
  source "$VM_INIT_REPO_ROOT/modules/shell.sh"
  mock_shell_install
  fisher_present_for() { return 0; }
  run_quiet() { read -r -t 1 _leaked || true; }
  run install_shell
  [ "$status" -eq 0 ]
  [[ "$output" == *"Updating Fisher plugins (alice)"* ]]
  [[ "$output" == *"Updating Fisher plugins (bob)"* ]]
}

@test "install_shell: installs fisher for a user who lacks it even when root has it" {
  source "$VM_INIT_REPO_ROOT/modules/shell.sh"
  mock_shell_install
  fisher_present_for() { [[ "$1" == root ]]; }
  install_fisher_tide() { echo "installed-for:$1"; }
  run_fish_as() { echo "ran:$1:$2"; }
  run install_shell
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed-for:alice"* ]]
  [[ "$output" == *"ran:root:fisher update"* ]]
  [[ "$output" != *"ran:alice:fisher update"* ]]
}

@test "install_shell: fails when changing a human user's shell fails" {
  source "$VM_INIT_REPO_ROOT/modules/shell.sh"
  mock_shell_install
  chsh() { [[ "$3" != alice ]] || return 1; printf '%s\n' "$2" > "$TEST_TMPDIR/$3.shell"; }
  fisher_present_for() { return 0; }
  run install_shell
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to change shell for alice"* ]]
}

@test "install_python: fails early when pipx is missing" {
  # shellcheck source=/dev/null
  source "${VM_INIT_REPO_ROOT}/modules/python.sh"
  yq() { echo uv; }
  old_path="$PATH"
  mkdir -p "$TEST_TMPDIR/bin"
  PATH="$TEST_TMPDIR/bin"

  run install_python

  PATH="$old_path"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Missing required command(s)"* ]]
  [[ "$output" == *"pipx"* ]]
}

# ---------- vm_init_note ----------

@test "vm_init_note: appends to the notes file when one is configured" {
  export VM_INIT_NOTES_FILE="$TEST_TMPDIR/notes"
  : > "$VM_INIT_NOTES_FILE"

  vm_init_note "Reboot required"
  vm_init_note "Log out and back in"

  run cat "$VM_INIT_NOTES_FILE"
  [[ "$output" == *"Reboot required"* ]]
  [[ "$output" == *"Log out and back in"* ]]
}

@test "vm_init_note: is a no-op when no notes file is configured" {
  unset VM_INIT_NOTES_FILE
  run vm_init_note "should vanish"
  [ "$status" -eq 0 ]
}

@test "vm_init_note: duplicates survive in the file and dedupe at render time" {
  export VM_INIT_NOTES_FILE="$TEST_TMPDIR/notes"
  : > "$VM_INIT_NOTES_FILE"

  vm_init_note "same note"
  vm_init_note "same note"

  # The file keeps both; the summary's awk pass is what collapses them.
  [ "$(wc -l < "$VM_INIT_NOTES_FILE")" -eq 2 ]
  [ "$(awk '!seen[$0]++' "$VM_INIT_NOTES_FILE" | wc -l)" -eq 1 ]
}

# ---------- apt_available ----------

@test "apt_available: true when apt-cache reports a candidate" {
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/apt-cache" <<'EOF'
#!/usr/bin/env bash
printf 'htop:\n  Installed: (none)\n  Candidate: 3.0.5-7build2\n'
EOF
  chmod +x "$TEST_TMPDIR/bin/apt-cache"
  export PATH="$TEST_TMPDIR/bin:$PATH"

  run apt_available htop
  [ "$status" -eq 0 ]
}

@test "apt_available: false when the candidate is (none) and nothing provides it" {
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/apt-cache" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  policy)   printf 'duf:\n  Installed: (none)\n  Candidate: (none)\n' ;;
  showpkg)  printf 'Package: duf\nVersions: \n\nReverse Depends: \nDependencies: \nProvides: \nReverse Provides: \n' ;;
esac
EOF
  chmod +x "$TEST_TMPDIR/bin/apt-cache"
  export PATH="$TEST_TMPDIR/bin:$PATH"

  run apt_available duf
  [ "$status" -ne 0 ]
}

@test "apt_available: false for a package apt-cache does not know at all" {
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/apt-cache" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TEST_TMPDIR/bin/apt-cache"
  export PATH="$TEST_TMPDIR/bin:$PATH"

  run apt_available totally-not-a-package
  [ "$status" -ne 0 ]
}

@test "apt_available: true for a virtual package with a real provider" {
  mkdir -p "$TEST_TMPDIR/bin"
  cat > "$TEST_TMPDIR/bin/apt-cache" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  policy)  printf 'editor:\n  Installed: (none)\n  Candidate: (none)\n' ;;
  showpkg) printf 'Package: editor\nVersions: \n\nReverse Provides: \nvim 2:9.0\n' ;;
esac
EOF
  chmod +x "$TEST_TMPDIR/bin/apt-cache"
  export PATH="$TEST_TMPDIR/bin:$PATH"

  run apt_available editor
  [ "$status" -eq 0 ]
}
