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
  yq_get() { echo true; }
  run_quiet() {
    if [[ "$1" == "download_file" ]]; then
      return 0
    fi
    return 1
  }

  run install_fisher_tide alice "$TEST_TMPDIR/home"

  [ "$status" -ne 0 ]
}

@test "install_shell: fails when changing a human user's shell fails" {
  # shellcheck source=/dev/null
  source "${VM_INIT_REPO_ROOT}/modules/shell.sh"
  yq() {
    case "$1" in
      ".shell.default_shell"*) echo env ;;
      ".shell.aliases"*) return 0 ;;
      *) return 0 ;;
    esac
  }
  yq_get() { echo false; }
  require_commands() { return 0; }
  human_users() { echo "alice:${TEST_TMPDIR}/home"; }
  usermod() { return 0; }
  chsh() { return 1; }

  run install_shell

  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to change default shell for alice"* ]]
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
