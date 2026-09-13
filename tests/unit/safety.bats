#!/usr/bin/env bats

setup() {
  load '../test_helper.bash'
  make_test_tmpdir
  load_common
}

teardown() { cleanup_test_tmpdir; }

@test "release checksum wrapper rejects a mismatch" {
  verify_sha256() { return 1; }
  run try_verify_github_asset unused https://example.invalid/asset.sha256
  [ "$status" -eq 1 ]
}

@test "missing checksum sidecar is an explicit warning" {
  verify_sha256() { return 2; }
  try_verify_github_asset unused https://example.invalid/asset.sha256
  [ "$VM_INIT_WARN_COUNT" -eq 1 ]
}

@test "release installer does not extract an asset with a bad checksum" {
  github_latest_version() { echo v1.0.0; }
  github_release_decide() { echo install; }
  download_file() { touch "$2"; }
  verify_sha256() { return 1; }
  tar() { touch "$TEST_TMPDIR/extracted"; }
  run download_github_release owner/tool 'tool.tar.gz' tool amd64
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_TMPDIR/extracted" ]
}

@test "no-upgrade skips installed release tools without network" {
  export VM_INIT_NO_UPGRADE=1
  is_installed() { return 0; }
  github_latest_version() { touch "$TEST_TMPDIR/network"; return 1; }
  run download_github_release owner/tool 'tool.tar.gz' tool amd64
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/network" ]
}

@test "kernel rollback removes the sole parameter under errexit" {
  export VM_INIT_GRUB_DEFAULTS="$TEST_TMPDIR/grub"
  printf 'GRUB_CMDLINE_LINUX_DEFAULT="mitigations=off"\n' > "$VM_INIT_GRUB_DEFAULTS"
  run bash -c 'set -uo pipefail; source "$1"; source "$2"; run_with_errexit _kernel_cmdline_remove mitigations=off' _ \
    "$VM_INIT_COMMON_SH" "$VM_INIT_REPO_ROOT/modules/kernel.sh"
  [ "$status" -eq 0 ]
  grep -qx 'GRUB_CMDLINE_LINUX_DEFAULT=""' "$VM_INIT_GRUB_DEFAULTS"
}

@test "state keys are literal and cannot replace a similarly named tool" {
  export VM_INIT_STATE_DIR="$TEST_TMPDIR/state"
  export VM_INIT_STATE_FILE="$VM_INIT_STATE_DIR/state"
  state_set github_release.tool-one v1
  state_set github_release.tool.one v2
  [ "$(state_get github_release.tool-one)" = v1 ]
  [ "$(state_get github_release.tool.one)" = v2 ]
}

@test "snapshot restores a symlink and removes a newly created file" {
  mkdir -p "$TEST_TMPDIR/etc"
  ln -s original-target "$TEST_TMPDIR/etc/resolv.conf"
  snapshot_paths "$TEST_TMPDIR/backup" "$TEST_TMPDIR/etc/resolv.conf" "$TEST_TMPDIR/etc/new.conf"
  rm "$TEST_TMPDIR/etc/resolv.conf"
  echo replacement > "$TEST_TMPDIR/etc/resolv.conf"
  touch "$TEST_TMPDIR/etc/new.conf"
  restore_paths "$TEST_TMPDIR/backup"
  [ "$(readlink "$TEST_TMPDIR/etc/resolv.conf")" = original-target ]
  [ ! -e "$TEST_TMPDIR/etc/new.conf" ]
}

@test "package wait detects a real POSIX lock held by another process" {
  touch "$TEST_TMPDIR/lock"
  python3 - "$TEST_TMPDIR/lock" "$TEST_TMPDIR/ready" <<'PY' &
import fcntl, pathlib, sys, time
with open(sys.argv[1], 'r+') as lock:
    fcntl.lockf(lock, fcntl.LOCK_EX)
    pathlib.Path(sys.argv[2]).touch()
    time.sleep(10)
PY
  holder=$!
  for _ in {1..50}; do [[ ! -e "$TEST_TMPDIR/ready" ]] || break; sleep .05; done
  VM_INIT_APT_LOCK_TIMEOUT=0 run wait_apt_lock "$TEST_TMPDIR/lock"
  kill "$holder"
  wait "$holder" 2>/dev/null || true
  [ "$status" -eq 124 ]
  run wait_apt_lock "$TEST_TMPDIR/lock"
  [ "$status" -eq 0 ]
}

@test "firewall verification compares complete ports, actions, direction and family" {
  source "$VM_INIT_REPO_ROOT/modules/ufw.sh"
  for row in '2222/tcp  ALLOW IN  Anywhere' '22  DENY IN  Anywhere' '22  ALLOW OUT  Anywhere' '22 (v6)  ALLOW IN  Anywhere (v6)'; do
    run ufw_rule_present 22 "$row" 4
    [ "$status" -ne 0 ]
  done
  run ufw_rule_present 22 '22  ALLOW IN  Anywhere' 4
  [ "$status" -eq 0 ]
  run ufw_rule_present OpenSSH 'OpenSSH (v6)  ALLOW IN  Anywhere (v6)' 6
  [ "$status" -eq 0 ]
}

@test "firewall reconciliation removes only obsolete tagged rules in descending order" {
  source "$VM_INIT_REPO_ROOT/modules/ufw.sh"
  rules=$'[ 1] 22/tcp  ALLOW IN  Anywhere # vm-init\n[ 2] 8080  ALLOW IN  Anywhere # vm-init\n[ 3] 9090  ALLOW IN  Anywhere # administrator\n[ 4] 8080 (v6)  ALLOW IN  Anywhere (v6) # vm-init'
  run ufw_stale_rule_numbers 22/tcp "$rules"
  [ "$status" -eq 0 ]
  [ "$output" = $'4\n2' ]
}

@test "existing firewall rules are recognized while the firewall is inactive" {
  source "$VM_INIT_REPO_ROOT/modules/ufw.sh"
  run ufw_rule_exists 'Nginx Full' $"ufw allow 'Nginx Full' comment 'administrator'"
  [ "$status" -eq 0 ]
  run ufw_rule_exists 22/tcp 'ufw allow 2222/tcp'
  [ "$status" -ne 0 ]
}

@test "SSH port is included in effective firewall rules" {
  source "$VM_INIT_REPO_ROOT/modules/ufw.sh"
  CONFIG="$TEST_TMPDIR/firewall.yml"
  echo 'ufw: {allow: [OpenSSH]}' > "$CONFIG"
  SSH_CONNECTION='198.51.100.1 4242 192.0.2.1 2222' run ufw_effective_rules
  [[ "$output" == *2222/tcp* ]]
}

@test "DNS transaction restores original files after every activation failure" {
  source "$VM_INIT_REPO_ROOT/modules/dns.sh"
  export VM_INIT_STATE_DIR="$TEST_TMPDIR/state"
  export VM_INIT_DNS_ROOT="$TEST_TMPDIR/system"
  export CONFIG="$TEST_TMPDIR/dns.yml"
  echo 'dns: {enabled: true}' > "$CONFIG"
  mkdir -p "$VM_INIT_DNS_ROOT/etc/systemd/system" "$VM_INIT_DNS_ROOT/etc/systemd/resolved.conf.d" "$VM_INIT_DNS_ROOT/usr/local/sbin" "$VM_INIT_DNS_ROOT/usr/local/bin"
  echo original > "$VM_INIT_DNS_ROOT/etc/systemd/resolved.conf.d/99-vm-init-dnsproxy.conf"
  ln -s original-resolver "$VM_INIT_DNS_ROOT/etc/resolv.conf"
  require_commands() { return 0; }
  install_dnsproxy_binary() { echo new > "$VM_INIT_DNS_ROOT/usr/local/bin/dnsproxy"; }
  ensure_systemd_resolved() { return 0; }
  apt_get() { return 0; }
  resolvectl() { return 0; }
  systemctl() {
    if [[ "$1" == is-active || "$1" == is-enabled ]]; then [[ "${*: -1}" == systemd-resolved ]]; return; fi
    if [[ "$1 ${2:-}" == "$failure" && ! -e "$TEST_TMPDIR/failed-once" ]]; then touch "$TEST_TMPDIR/failed-once"; return 1; fi
    return 0
  }
  wait_for_dnsproxy() { [[ "$failure" != listening ]]; }
  verify_doh_resolves() { [[ "$failure" != resolution ]]; }
  dns_verify_routing() { [[ "$failure" != routing ]]; }
  for failure in 'restart dnsproxy' 'restart systemd-resolved' listening resolution routing; do
    export failure
    rm -f "$TEST_TMPDIR/failed-once"
    run_module_with_stubs dns install_dns require_commands install_dnsproxy_binary \
      ensure_systemd_resolved apt_get resolvectl systemctl wait_for_dnsproxy \
      verify_doh_resolves dns_verify_routing
    [ "$status" -ne 0 ]
    [ "$(cat "$VM_INIT_DNS_ROOT/etc/systemd/resolved.conf.d/99-vm-init-dnsproxy.conf")" = original ]
    [ "$(readlink "$VM_INIT_DNS_ROOT/etc/resolv.conf")" = original-resolver ]
    [ ! -e "$VM_INIT_DNS_ROOT/usr/local/bin/dnsproxy" ]
    [ ! -e "$VM_INIT_DNS_ROOT/etc/systemd/system/dnsproxy.service" ]
  done
}

@test "ordinary name resolution does not verify an incorrect DNS upstream" {
  source "$VM_INIT_REPO_ROOT/modules/dns.sh"
  export VM_INIT_DNS_ROOT="$TEST_TMPDIR/system"
  mkdir -p "$VM_INIT_DNS_ROOT/etc"
  ln -s /run/systemd/resolve/stub-resolv.conf "$VM_INIT_DNS_ROOT/etc/resolv.conf"
  systemctl() { if [[ "$1" == show ]]; then echo 'argv[]=/usr/local/bin/dnsproxy --upstream=https://wrong.invalid --listen=127.0.0.1 --port=5353 ;'; fi; }
  resolvectl() { [[ "$1" != dns ]] || echo 'Global: 127.0.0.1:5353'; }
  getent() { echo '93.184.216.34 example.com'; }
  ip() { return 0; }
  run dns_verify_routing 127.0.0.1 5353 https://wanted.invalid
  [ "$status" -ne 0 ]
  [[ "$output" == *'differs from the requested upstream'* ]]
}

@test "retry commands preserve spaces, literal shell characters, users and options" {
  source "$VM_INIT_REPO_ROOT/modules/_actions.sh"
  VM_INIT_EXECUTABLE="$TEST_TMPDIR/bin with spaces/vm-init"
  VM_INIT_SOURCE_CONFIG="$TEST_TMPDIR/config with spaces.yml"
  VM_INIT_FORCE=1 VM_INIT_NO_UPGRADE=1 VM_INIT_TARGET_USERS='alice bob'
  command=$(retry_command apply dns)
  # Parse our own generated shell quoting with a capture-only sudo function.
  sudo() { printf '%s\n' "$@"; }
  output=$(eval "$command")
  [[ "$output" == *"$VM_INIT_EXECUTABLE"* ]]
  [[ "$output" == *"$VM_INIT_SOURCE_CONFIG"* ]]
  [[ "$output" == *alice,bob* ]]
  [[ "$output" == *--force* && "$output" == *--no-upgrade* ]]
}

@test "saved retry context survives edits to the original config" {
  source "$VM_INIT_REPO_ROOT/modules/_actions.sh"
  export VM_INIT_STATE_DIR="$TEST_TMPDIR/state"
  export VM_INIT_STATE_FILE="$VM_INIT_STATE_DIR/state"
  CONFIG="$TEST_TMPDIR/custom config.yml"
  echo 'shell: {enabled: true}' > "$CONFIG"
  VM_INIT_CONFIG_JSON='{"shell":{"enabled":true}}'
  VM_INIT_TARGET_USERS='alice bob' VM_INIT_RUN_ID=test-run
  save_run_context
  state_set last.failed shell
  state_set last.force 1
  state_set last.no_upgrade 1
  echo '{}' > "$CONFIG"
  load_failed_run
  [ "$VM_INIT_ONLY" = shell ]
  [ "$VM_INIT_FORCE:$VM_INIT_NO_UPGRADE" = 1:1 ]
  jq -e '.shell.enabled and .users == ["alice", "bob"]' "$CONFIG"
  [ "$(_sha256_of "$CONFIG")" = "$VM_INIT_CONFIG_FINGERPRINT" ]
}

@test "shell verification checks the second selected account and ignores others" {
  source "$VM_INIT_REPO_ROOT/modules/shell.sh"
  CONFIG="$TEST_TMPDIR/shell.yml"
  echo 'shell: {default_shell: fish, aliases: {ll: "ls -l"}, fisher: false}' > "$CONFIG"
  target_users() { printf 'alice:%s/alice\nbob:%s/bob\n' "$TEST_TMPDIR" "$TEST_TMPDIR"; }
  getent() { printf '%s:x:1000:1000::/unused:/usr/bin/fish\n' "$2"; }
  is_installed() { return 0; }
  fish_aliases_match_for() { return 0; }
  for user in alice bob; do
    mkdir -p "$TEST_TMPDIR/$user/.config/fish/conf.d"
    render_shell_config fish > "$TEST_TMPDIR/$user/.config/fish/conf.d/90-vm-init.fish"
  done
  run verify_shell
  [ "$status" -eq 0 ]
  echo '# deleted aliases' > "$TEST_TMPDIR/bob/.config/fish/conf.d/90-vm-init.fish"
  run verify_shell
  [ "$status" -eq 1 ]
  [[ "$output" == *'bob: managed aliases or integrations differ'* ]]
}

@test "Docker verification checks membership for every selected non-root account" {
  source "$VM_INIT_REPO_ROOT/modules/docker.sh"
  VM_INIT_TARGET_USERS='root alice bob'
  require_commands() { return 0; }
  is_installed() { return 0; }
  run_quiet() { return 0; }
  systemctl() { return 0; }
  id() { if [[ "$2" == alice ]]; then echo 'alice docker'; else echo bob; fi; }
  run verify_docker
  [ "$status" -eq 1 ]
  [[ "$output" == *'bob is not in the docker group'* ]]
  [[ "$output" != *'root is not'* ]]
}

@test "firewall failure restores files and active state" {
  source "$VM_INIT_REPO_ROOT/modules/ufw.sh"
  export VM_INIT_STATE_DIR="$TEST_TMPDIR/state" VM_INIT_UFW_ROOT="$TEST_TMPDIR/system"
  export CONFIG="$TEST_TMPDIR/ufw.yml"
  echo 'ufw: {allow: [22/tcp], ipv6: true}' > "$CONFIG"
  mkdir -p "$VM_INIT_UFW_ROOT/etc/ufw" "$VM_INIT_UFW_ROOT/etc/default"
  echo original > "$VM_INIT_UFW_ROOT/etc/ufw/user.rules"
  echo IPV6=no > "$VM_INIT_UFW_ROOT/etc/default/ufw"
  require_commands() { return 0; }
  ufw_lock() { return 0; }
  detect_ssh_connection() { SSH_CONNECTION=''; }
  is_installed() { return 0; }
  run_quiet() { "$@"; }
  # BSD sed does not accept GNU's -i spelling; only adapt that spelling.
  sed() { if [[ "$1" == -i && "$(uname -s)" == Darwin ]]; then shift; command sed -i '' "$@"; else command sed "$@"; fi; }
  systemctl() { return 0; }
  ufw() {
    case "$*" in
      status) echo 'Status: active' ;;
      allow*) echo modified > "$VM_INIT_UFW_ROOT/etc/ufw/user.rules"; return 1 ;;
      reload) touch "$TEST_TMPDIR/restored-active" ;;
    esac
  }
  run_module_with_stubs ufw install_ufw require_commands ufw_lock \
    detect_ssh_connection is_installed run_quiet sed systemctl ufw
  [ "$status" -eq 1 ]
  [ "$(cat "$VM_INIT_UFW_ROOT/etc/ufw/user.rules")" = original ]
  [ "$(cat "$VM_INIT_UFW_ROOT/etc/default/ufw")" = IPV6=no ]
  [ -e "$TEST_TMPDIR/restored-active" ]
}

@test "firewall confirmation requires a new SSH session and passes without run lock" {
  source "$VM_INIT_REPO_ROOT/modules/ufw.sh"
  export VM_INIT_STATE_DIR="$TEST_TMPDIR/state"
  mkdir -p "$VM_INIT_STATE_DIR/backup"
  touch "$VM_INIT_STATE_DIR/backup/ready"
  original='198.51.100.1 4000 192.0.2.1 2222'
  printf '%s\n%s\n' "$VM_INIT_STATE_DIR/backup" "$original" > "$VM_INIT_STATE_DIR/firewall-pending"
  acquire_run_lock() { return 1; }
  ufw_lock() { return 0; }
  systemctl() { return 0; }
  SSH_CONNECTION="$original" run confirm_firewall
  [ "$status" -eq 1 ]
  [ -f "$VM_INIT_STATE_DIR/firewall-pending" ]
  touch "$VM_INIT_STATE_DIR/backup/rollback-started"
  SSH_CONNECTION='198.51.100.1 4001 192.0.2.1 2222' run confirm_firewall
  [ "$status" -eq 1 ]
  [ -f "$VM_INIT_STATE_DIR/firewall-pending" ]
  rm "$VM_INIT_STATE_DIR/backup/rollback-started"
  SSH_CONNECTION='198.51.100.1 4001 192.0.2.1 2222' run confirm_firewall
  [ "$status" -eq 0 ]
  [ ! -f "$VM_INIT_STATE_DIR/firewall-pending" ]
  [ ! -d "$VM_INIT_STATE_DIR/backup" ]
}

@test "removed APT packages are installed again with no-upgrade" {
  VM_INIT_NO_UPGRADE=1 VM_INIT_FORCE=0
  dpkg-query() { printf 'deinstall ok config-files\t1.0\n'; }
  run_quiet() { printf '%s\n' "$*" > "$TEST_TMPDIR/command"; }
  apt_install_with_report jq
  [[ "$(cat "$TEST_TMPDIR/command")" == *'install -y -q jq'* ]]
}

@test "DNS snapshot accepts an image without an active resolved service" {
  export VM_INIT_DNS_ROOT="$TEST_TMPDIR/system"
  mkdir -p "$VM_INIT_DNS_ROOT/etc"
  echo 'nameserver 192.0.2.53' > "$VM_INIT_DNS_ROOT/etc/resolv.conf"
  systemctl() { return 1; }
  resolvectl() { touch "$TEST_TMPDIR/unexpected-probe"; return 1; }
  dns_save_state "$TEST_TMPDIR/snapshot"
  [ ! -e "$TEST_TMPDIR/unexpected-probe" ]
  [ -f "$TEST_TMPDIR/snapshot/paths" ]
}

@test "Fish verification detects aliases overridden after the managed file loads" {
  command -v fish >/dev/null || skip 'requires fish'
  source "$VM_INIT_REPO_ROOT/modules/shell.sh"
  CONFIG="$TEST_TMPDIR/shell.yml"
  echo 'shell: {aliases: {ll: "ls -l"}}' > "$CONFIG"
  mkdir -p "$TEST_TMPDIR/config/fish/conf.d" "$TEST_TMPDIR/data"
  render_shell_config fish > "$TEST_TMPDIR/config/fish/conf.d/90-vm-init.fish"
  run_fish_as() { env XDG_CONFIG_HOME="$TEST_TMPDIR/config" XDG_DATA_HOME="$TEST_TMPDIR/data" fish -c "$2"; }
  run fish_aliases_match_for alice
  [ "$status" -eq 0 ]
  echo 'alias ll "ls -a"' > "$TEST_TMPDIR/config/fish/config.fish"
  run fish_aliases_match_for alice
  [ "$status" -eq 1 ]
}

@test "mutation lock excludes unrelated runs and permits an inherited preparation child" {
  command -v flock >/dev/null || skip 'requires Linux flock'
  export VM_INIT_STATE_DIR="$TEST_TMPDIR/state"
  acquire_run_lock
  run bash -c 'source "$VM_INIT_COMMON_SH"; source "$VM_INIT_REPO_ROOT/modules/_safety.sh"; acquire_run_lock'
  [ "$status" -eq 0 ]
  run env -u VM_INIT_LOCK_FD bash -c 'source "$VM_INIT_COMMON_SH"; source "$VM_INIT_REPO_ROOT/modules/_safety.sh"; acquire_run_lock'
  [ "$status" -eq 1 ]
  [[ "$output" == *'Another vm-init change is running'* ]]
}

@test "quiet commands report progress and preserve a failing exit status" {
  VM_INIT_PROGRESS_INTERVAL=.05 run run_quiet bash -c 'sleep .2; echo failure-detail; exit 7'
  [ "$status" -eq 7 ]
  [[ "$output" == *'Still working ('* ]]
  [[ "$output" == *failure-detail* ]]
}

@test "shell file replacement runs as the selected account and replaces an old file" {
  source "$VM_INIT_REPO_ROOT/modules/shell.sh"
  managed="$TEST_TMPDIR/account/.config/fish/conf.d/90-vm-init.fish"
  run_as_user() { echo "$1" > "$TEST_TMPDIR/writing-account"; shift; "$@"; }
  printf 'old alias\n' | write_shell_file alice "$managed"
  printf 'new alias\n' | write_shell_file alice "$managed"
  [ "$(cat "$TEST_TMPDIR/writing-account")" = alice ]
  [ "$(cat "$managed")" = 'new alias' ]
}
