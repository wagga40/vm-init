#!/usr/bin/env bats
# CLI help formatting tests for vm-init.sh, scripts/install.sh, and
# modules/recover-dns.sh. These assert the human-facing output of each
# script's --help (structure, sections, and key flags) and that unknown
# flags print usage + exit 1.

setup() {
  load '../test_helper.bash'
  export INSTALL_SH="${VM_INIT_REPO_ROOT}/scripts/install.sh"
  export RECOVER_SH="${VM_INIT_REPO_ROOT}/modules/recover-dns.sh"
}

# ---------- vm-init.sh help structure ----------

@test "vm-init --help contains structured sections and status legend" {
  run "$VM_INIT_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"Options:"* ]]
  [[ "$output" == *"Modules:"* ]]
  [[ "$output" == *"Status legend:"* ]]
  [[ "$output" == *"Examples:"* ]]
  [[ "$output" == *"Recovery:"* ]]
  # Legend labels should all be present
  [[ "$output" == *"step completed"* ]]
  [[ "$output" == *"skipped"* ]]
  [[ "$output" == *"completed with warnings"* ]]
  [[ "$output" == *"module failed"* ]]
  [[ "$output" == *"--update"* ]]
}

@test "vm-init --help groups options under selection/execution/logging/info" {
  run "$VM_INIT_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Selection"* ]]
  [[ "$output" == *"Execution"* ]]
  [[ "$output" == *"Logging"* ]]
  [[ "$output" == *"Info"* ]]
}

# ---------- install.sh --help ----------

@test "install.sh --help exits 0 and mentions all CLI flags" {
  run bash "$INSTALL_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"Options:"* ]]
  [[ "$output" == *"Environment:"* ]]
  [[ "$output" == *"Examples:"* ]]
  [[ "$output" == *"--version"* ]]
  [[ "$output" == *"--prefix"* ]]
  [[ "$output" == *"--no-symlink"* ]]
}

@test "install.sh -h is an alias for --help" {
  run bash "$INSTALL_SH" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"vm-init installer"* ]]
}

@test "install.sh rejects unknown options with usage" {
  run bash "$INSTALL_SH" --nonexistent-flag
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option"* ]]
  [[ "$output" == *"Usage:"* ]]
}

# ---------- modules/recover-dns.sh --help ----------

@test "recover-dns.sh --help exits 0 and mentions all CLI flags" {
  run bash "$RECOVER_SH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"Options:"* ]]
  [[ "$output" == *"Examples:"* ]]
  [[ "$output" == *"--iface"* ]]
  [[ "$output" == *"--with-fallback"* ]]
  [[ "$output" == *"--fallback"* ]]
}

@test "recover-dns.sh rejects unknown options with usage" {
  run bash "$RECOVER_SH" --nonexistent-flag
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option"* ]]
  [[ "$output" == *"Usage:"* ]]
}

# ---------- color detection ----------

@test "vm-init --help emits no ANSI escapes when NO_COLOR is set" {
  NO_COLOR=1 run "$VM_INIT_SH" --help
  [ "$status" -eq 0 ]
  # No escape byte 0x1b in output
  if printf '%s' "$output" | grep -q $'\x1b'; then
    echo "Expected no ANSI escapes but found some in output" >&2
    return 1
  fi
}

@test "vm-init --help emits ANSI escapes when VM_INIT_FORCE_COLOR=1" {
  VM_INIT_FORCE_COLOR=1 run "$VM_INIT_SH" --help
  [ "$status" -eq 0 ]
  # At least one escape byte 0x1b in output
  printf '%s' "$output" | grep -q $'\x1b'
}
