#!/usr/bin/env bash
# Shared test helpers for the vm-init bats suite.
#
# Tests are organized in tests/unit/ (no root, no systemd) and
# tests/integration/ (exercise the full orchestrator via --dry-run etc).

TEST_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_INIT_REPO_ROOT="$(cd "${TEST_HELPER_DIR}/.." && pwd)"
export VM_INIT_REPO_ROOT
export VM_INIT_SH="${VM_INIT_REPO_ROOT}/vm-init.sh"
export VM_INIT_COMMON_SH="${VM_INIT_REPO_ROOT}/modules/_common.sh"
export VM_INIT_DEFAULT_CONFIG="${VM_INIT_REPO_ROOT}/vm-init.yml"

# Source _common.sh into the current shell for unit tests.
# Suppress output during sourcing so it doesn't pollute test assertions.
load_common() {
  # shellcheck disable=SC1090
  source "$VM_INIT_COMMON_SH"
}

# Create a temporary directory unique to the current test; cleaned up in teardown.
make_test_tmpdir() {
  TEST_TMPDIR=$(mktemp -d)
  export TEST_TMPDIR
}

cleanup_test_tmpdir() {
  [[ -n "${TEST_TMPDIR:-}" && -d "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
}

# Put a fake binary on PATH that emits fixed stdout and exits with a given code.
# Usage: stub_bin <name> <exit_code> [<stdout_file>]
#   <stdout_file> path to a file whose contents will be printed by the stub.
stub_bin() {
  local name="$1" code="$2" stdout_file="${3:-}"
  mkdir -p "$TEST_TMPDIR/bin"
  if [[ -n "$stdout_file" ]]; then
    cat > "$TEST_TMPDIR/bin/$name" <<EOF
#!/usr/bin/env bash
cat '${stdout_file}'
exit ${code}
EOF
  else
    cat > "$TEST_TMPDIR/bin/$name" <<EOF
#!/usr/bin/env bash
exit ${code}
EOF
  fi
  chmod +x "$TEST_TMPDIR/bin/$name"
  export PATH="$TEST_TMPDIR/bin:$PATH"
}

# Create a minimal valid vm-init.yml for tests that want to exercise the
# orchestrator without touching the real one.
#
# All modules are enabled so --only/--skip tests can distinguish between
# "excluded by filter" and "disabled in config". Nothing destructive happens
# because callers use --dry-run.
make_minimal_config() {
  local dest="$1"
  cat > "$dest" <<'YAML'
apt:
  enabled: true
  packages: {}
ufw:
  enabled: true
  defaults:
    incoming: deny
    outgoing: allow
  allow: []
fail2ban:
  enabled: true
  bantime: 1h
  findtime: 10m
  maxretry: 5
  banaction: auto
  jails:
    sshd:
      enabled: true
dns:
  enabled: true
  server: https://base.dns.mullvad.net/dns-query
  listen_port: 5353
docker:
  enabled: true
python:
  enabled: true
  tools: []
github_tools:
  enabled: true
  gh: true
  act: true
github_releases:
  enabled: true
  generic: []
  custom: {}
shell:
  enabled: true
  default_shell: fish
  aliases: {}
YAML
}

# Create a vm-init.yml with some modules explicitly disabled, for tests that
# need --list-modules to show "off".
make_mixed_config() {
  local dest="$1"
  cat > "$dest" <<'YAML'
apt:
  enabled: true
  packages: {}
ufw:
  enabled: true
  defaults:
    incoming: deny
    outgoing: allow
  allow: []
fail2ban:
  enabled: true
  bantime: 1h
  findtime: 10m
  maxretry: 5
  banaction: auto
  jails:
    sshd:
      enabled: true
dns:
  enabled: true
  server: https://base.dns.mullvad.net/dns-query
  listen_port: 5353
docker:
  enabled: false
python:
  enabled: true
  tools: []
github_tools:
  enabled: false
  gh: true
  act: true
github_releases:
  enabled: true
  generic: []
  custom: {}
shell:
  enabled: true
  default_shell: fish
  aliases: {}
YAML
}
