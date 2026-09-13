#!/usr/bin/env bats

setup() {
  load '../test_helper.bash'
  make_test_tmpdir
  # Load the real runner/reporting functions without executing root checks or
  # provisioning. Each scenario runs in a fresh Bash with production errexit.
  cat > "$TEST_TMPDIR/harness.sh" <<'SH'
set -euo pipefail
export VM_INIT_NO_COLOR=1 VM_INIT_FORCE_COLOR=0
source "$VM_INIT_COMMON_SH"
source "$VM_INIT_REPO_ROOT/modules/_actions.sh"
VM_INIT_MODULE_NAMES=() VM_INIT_MODULE_STATUS=() VM_INIT_MODULE_DETAIL=() VM_INIT_MODULE_ELAPSED=()
VM_INIT_DRY_RUN=0 VM_INIT_VERIFY=0 VM_INIT_VERBOSE=0 VM_INIT_WARN_COUNT=0
VM_INIT_START_TS=$(date +%s)
VM_INIT_RUN_ID=test-run VM_INIT_VERSION=test
VM_INIT_STATE_DIR="$TEST_TMPDIR/state"
VM_INIT_STATE_FILE="$VM_INIT_STATE_DIR/state"
VM_INIT_NOTES_FILE="$TEST_TMPDIR/notes"
mkdir -p "$VM_INIT_STATE_DIR"
: > "$VM_INIT_NOTES_FILE"
SH
  awk '
    /^record_module_status\(\)/ { printing=1 }
    /^if \[\[ "\$VM_INIT_SETUP"/ { printing=0 }
    /^reconcile_firewall_result\(\)/ { printing=1 }
    /^reconcile_firewall_result$/ { printing=0 }
    printing
  ' "$VM_INIT_SH" >> "$TEST_TMPDIR/harness.sh"
  cat >> "$TEST_TMPDIR/harness.sh" <<'SH'
_module_should_run() { return 0; }
retry_command() { printf 'sudo vm-init %s' "$*"; }
SH
}

teardown() { cleanup_test_tmpdir; }

@test "informational and session notes leave successful modules ready" {
  run bash -c '
    source "$TEST_TMPDIR/harness.sh"
    install_dns() { vm_init_note "DNS routing verified; recovery is available."; }
    install_shell() { vm_init_note "Start a new session to use fish." session; }
    run_module dns dns.sh install_dns
    run_module shell shell.sh install_shell
    print_summary
    [[ "${VM_INIT_MODULE_STATUS[*]}" == "ok ok" ]]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'ready: 2   needs action: 0   warned: 0   failed: 0'* ]]
  [[ "$output" == *$'Session changes\n  - shell: Start a new session'* ]]
  [[ "$output" == *$'Notes\n  - dns: DNS routing verified'* ]]
  [[ "$output" == *'[OK] Setup complete.'* ]]
  [[ "$output" != *'Required actions'* ]]
  [[ "$output" != *'with warnings'* ]]
}

@test "a warning is completed with caveats and does not imply an action" {
  run bash -c '
    source "$TEST_TMPDIR/harness.sh"
    install_dns() { log_warn "No checksum sidecar; checksum skipped"; vm_init_note "DNS recovery is available."; }
    run_module dns dns.sh install_dns
    print_summary
    [[ "${VM_INIT_MODULE_STATUS[0]}" == warned ]]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'needs action: 0   warned: 1'* ]]
  [[ "$output" == *$'Warnings\n  - dns: No checksum sidecar; checksum skipped'* ]]
  [[ "$output" == *'Setup completed with warnings.'* ]]
  [[ "$output" != *'Needs action'* ]]
  [[ "$output" != *'[OK] Setup complete.'* ]]
}

@test "required actions have reasons and take priority over ordinary notes" {
  run bash -c '
    source "$TEST_TMPDIR/harness.sh"
    touch "$VM_INIT_STATE_DIR/firewall-pending"
    install_ufw() { vm_init_note "Confirm from a new SSH session." action "confirm firewall"; }
    install_shell() {
      vm_init_note "Review config.fish for overrides." action "review alias overrides"
      vm_init_note "Start a new session." session
    }
    run_module ufw ufw.sh install_ufw
    run_module shell shell.sh install_shell
    print_summary
    [[ "${VM_INIT_MODULE_STATUS[*]}" == "needs_action needs_action" ]]
    [[ "$(state_get module.shell.status)" == needs_action ]]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'(confirm firewall)'* ]]
  [[ "$output" == *'(review alias overrides)'* ]]
  [[ "$output" == *'needs action: 2   warned: 0'* ]]
  [[ "$output" == *$'Required actions\n  1. ufw: Confirm from a new SSH session.\n  2. shell: Review config.fish'* ]]
  [[ "$output" == *'Setup finished; action required for 2 modules.'* ]]
  [[ "$output" == *'After completing the actions, verify with: sudo vm-init status'* ]]
  [[ "$output" != *'with warnings'* ]]
  [[ "$output" != *'[OK] Setup complete.'* ]]
}

@test "an action does not hide warnings from the same module" {
  run bash -c '
    source "$TEST_TMPDIR/harness.sh"
    install_shell() {
      log_warn "Plugin update failed"
      vm_init_note "Review aliases." action "review alias overrides"
    }
    run_module shell shell.sh install_shell
    print_summary
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'(review alias overrides; 1 warning(s))'* ]]
  [[ "$output" == *$'Warnings\n  - shell: Plugin update failed'* ]]
  [[ "$output" == *'action required for 1 module.'* ]]
}

@test "warnings raised in a nested subshell are retained in the outcome" {
  run bash -c '
    source "$TEST_TMPDIR/harness.sh"
    install_dns() { (log_warn "Nested warning"); }
    run_module dns dns.sh install_dns
    print_summary
    [[ "${VM_INIT_MODULE_STATUS[0]}" == warned ]]
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'Setup completed with warnings.'* ]]
}

@test "module failure takes precedence and unfinished work is retried" {
  run bash -c '
    source "$TEST_TMPDIR/harness.sh"
    install_kernel() {
      vm_init_note "Reboot when convenient." action "reboot required"
      log_warn "A warning before failure"
      false
      touch "$TEST_TMPDIR/should-not-run"
    }
    run_module kernel kernel.sh install_kernel
    [[ "${VM_INIT_MODULE_STATUS[0]}" == failed ]]
    record_module_status shell not_run "stopped after earlier failure"
    print_summary
  '
  [ "$status" -eq 1 ]
  [ ! -f "$TEST_TMPDIR/should-not-run" ]
  [[ "$output" == *'Not run'* ]]
  [[ "$output" == *'warned: 0   failed: 1'* ]]
  [[ "$output" == *'not run: 1'* ]]
  [[ "$output" == *'Required actions'* ]]
  [[ "$output" == *'sudo vm-init apply kernel,shell'* ]]
  [[ "$output" != *'Setup complete'* ]]
}

@test "confirmed firewall clears its action without an empty action section" {
  run bash -c '
    source "$TEST_TMPDIR/harness.sh"
    touch "$VM_INIT_STATE_DIR/firewall-pending"
    install_ufw() { vm_init_note "Confirm firewall." action "confirm firewall"; }
    run_module ufw ufw.sh install_ufw
    rm "$VM_INIT_STATE_DIR/firewall-pending"
    echo "test-run confirmed" > "$VM_INIT_STATE_DIR/firewall-result"
    reconcile_firewall_result
    print_summary
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'(confirmed from a new session)'* ]]
  [[ "$output" == *'ready: 1   needs action: 0'* ]]
  [[ "$output" != *'Required actions'* ]]
}

@test "confirmed firewall retains unrelated warnings" {
  run bash -c '
    source "$TEST_TMPDIR/harness.sh"
    touch "$VM_INIT_STATE_DIR/firewall-pending"
    install_ufw() { log_warn "A firewall caveat"; vm_init_note "Confirm firewall." action "confirm firewall"; }
    run_module ufw ufw.sh install_ufw
    rm "$VM_INIT_STATE_DIR/firewall-pending"
    echo "test-run confirmed" > "$VM_INIT_STATE_DIR/firewall-result"
    reconcile_firewall_result
    print_summary
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'needs action: 0   warned: 1'* ]]
  [[ "$output" == *'Setup completed with warnings.'* ]]
  [[ "$output" != *'Required actions'* ]]
}

@test "expired firewall confirmation reports rollback as failure" {
  run bash -c '
    source "$TEST_TMPDIR/harness.sh"
    touch "$VM_INIT_STATE_DIR/firewall-pending"
    install_ufw() { vm_init_note "Confirm firewall." action "confirm firewall"; }
    run_module ufw ufw.sh install_ufw
    rm "$VM_INIT_STATE_DIR/firewall-pending"
    echo "test-run rolled_back" > "$VM_INIT_STATE_DIR/firewall-result"
    reconcile_firewall_result
    print_summary
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *'confirmation expired; previous firewall restored'* ]]
  [[ "$output" == *'failed: 1'* ]]
  [[ "$output" != *'Required actions'* ]]
  [[ "$output" != *'Setup complete'* ]]
}

@test "verification and JSON distinguish warnings from required actions" {
  run bash -c '
    source "$TEST_TMPDIR/harness.sh"
    VM_INIT_VERIFY=1
    install_dns() { :; }; install_kernel() { :; }
    verify_dns() { log_warn "Checksum unavailable"; }
    verify_kernel() { vm_init_note "Reboot, then run status." action "reboot required"; }
    verify_module dns dns.sh install_dns
    verify_module kernel kernel.sh install_kernel
    print_summary
    print_json_summary 3> "$TEST_TMPDIR/status.json"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'Verification finished; action required for 1 module.'* ]]
  [[ "$output" != *'[OK] Verification complete.'* ]]
  jq -e '
    .modules[0].status == "warned" and .modules[0].observed_state == "warnings" and
    .modules[1].status == "needs_action" and .modules[1].observed_state == "needs_action" and
    any(.messages[]; .kind == "action" and .module == "kernel" and .message == "Reboot, then run status.")
  ' "$TEST_TMPDIR/status.json"
}

@test "messages are deduplicated by module and never interpreted as escapes" {
  run bash -c '
    source "$TEST_TMPDIR/harness.sh"
    VM_INIT_CURRENT_MODULE=shell
    vm_init_note "Keep \\n literal" session
    vm_init_note "Keep \\n literal" session
    VM_INIT_CURRENT_MODULE=docker
    vm_init_note "Keep \\n literal" session
    print_next_steps
  '
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^  - ')" -eq 2 ]
  [[ "$output" == *'shell: Keep \n literal'* ]]
  [[ "$output" == *'docker: Keep \n literal'* ]]
}

@test "a dry run reports planned modules and no completion claim" {
  run bash -c '
    source "$TEST_TMPDIR/harness.sh"
    VM_INIT_DRY_RUN=1
    install_dns() { touch "$TEST_TMPDIR/should-not-run"; }
    dry_run_preview() { :; }
    run_module dns dns.sh install_dns
    print_summary
  '
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_TMPDIR/should-not-run" ]
  [[ "$output" == *'Planned'* ]]
  [[ "$output" == *'planned: 1'* ]]
  [[ "$output" == *'Dry run complete'* ]]
  [[ "$output" != *'Setup complete'* ]]
}
