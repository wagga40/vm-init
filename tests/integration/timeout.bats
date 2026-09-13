#!/usr/bin/env bats

setup() {
  load '../test_helper.bash'
  make_test_tmpdir
  [[ "$(uname -s)" == Linux ]] || skip 'requires Linux script with a controlling terminal'
  cat > "$TEST_TMPDIR/terminal.py" <<'PY'
import os
import signal
import sys
import termios


def terminal_stop(signum, _frame):
    # Fail promptly instead of leaving a stopped process behind on regression.
    print(f"Terminal access caused {signal.Signals(signum).name}", flush=True)
    sys.exit(1)


signal.signal(signal.SIGTTIN, terminal_stop)
signal.signal(signal.SIGTTOU, terminal_stop)
fd = int(sys.argv[1])
assert os.isatty(fd)
# APT can adjust terminal attributes even when all prompts are disabled.
termios.tcsetattr(fd, termios.TCSANOW, termios.tcgetattr(fd))
if fd == 0:
    assert input() == "terminal input"
print("Terminal access succeeded", flush=True)
PY
  cat > "$TEST_TMPDIR/runner.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$VM_INIT_COMMON_SH"
export VM_INIT_CMD_TIMEOUT=5
case "$VM_INIT_TIMEOUT_TEST_MODE" in
  input) run_maybe_timeout python3 "$TEST_TMPDIR/terminal.py" 0 ;;
  output) run_maybe_timeout python3 "$TEST_TMPDIR/terminal.py" 1 </dev/null ;;
  expire) VM_INIT_CMD_TIMEOUT=0.1 run_maybe_timeout sleep 10 ;;
  fail) run_maybe_timeout bash -c 'exit 42' ;;
esac
echo 'Continued after command'
SH
}

teardown() { cleanup_test_tmpdir; }

run_in_terminal() {
  export VM_INIT_TIMEOUT_TEST_MODE="$1"
  run bash -c 'printf "terminal input\n" | script -qec "bash \"$TEST_TMPDIR/runner.sh\"" /dev/null'
}

@test "timeout permits terminal reads and mode changes before configuration continues" {
  run_in_terminal input
  [ "$status" -eq 0 ]
  [[ "$output" == *'Terminal access succeeded'* ]]
  [[ "$output" == *'Continued after command'* ]]
}

@test "timeout permits terminal mode changes when stdin is redirected" {
  run_in_terminal output
  [ "$status" -eq 0 ]
  [[ "$output" == *'Terminal access succeeded'* ]]
  [[ "$output" == *'Continued after command'* ]]
}

@test "terminal commands still time out and preserve failure status" {
  run_in_terminal expire
  [ "$status" -eq 143 ]
  [[ "$output" != *'Continued after command'* ]]
  run_in_terminal fail
  [ "$status" -eq 42 ]
  [[ "$output" != *'Continued after command'* ]]
}
