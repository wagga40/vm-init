#!/usr/bin/env bats

setup() {
  load '../test_helper.bash'
  make_test_tmpdir
  load_common
  export VM_INIT_FORCE=0 VM_INIT_RESTORE_CONFIG=0 VM_INIT_DRY_RUN=0 VM_INIT_VERIFY=0
  export VM_INIT_CURRENT_MODULE=test VM_INIT_RUN_ID=test-run
  export VM_INIT_NOTES_FILE="$TEST_TMPDIR/notes"
}

teardown() { cleanup_test_tmpdir; }

shell_fixture() {
  source "$VM_INIT_REPO_ROOT/modules/shell.sh"
  export CONFIG="$TEST_TMPDIR/shell.yml" VM_INIT_TARGET_USERS=alice VM_INIT_CURRENT_MODULE=shell VM_INIT_NO_UPGRADE=1
  export VM_INIT_SHELL_PATH
  VM_INIT_SHELL_PATH=$(command -v bash)
  echo 'shell: {enabled: true, default_shell: bash, aliases: {ll: "ls -l"}}' > "$CONFIG"
  echo /bin/old-shell > "$TEST_TMPDIR/login"
  getent() { printf 'alice:x:1000:1000::%s/account:%s\n' "$TEST_TMPDIR" "$(cat "$TEST_TMPDIR/login")"; }
  target_users() { printf 'alice:%s/account\n' "$TEST_TMPDIR"; }
  ensure_apt_packages() { return 0; }
  run_as_user() { shift; "$@"; }
  chsh() { echo "$*" >> "$TEST_TMPDIR/chsh"; echo "$2" > "$TEST_TMPDIR/login"; }
}

@test "shell repeat apply does not replace files change login shell or repeat session notes" {
  shell_fixture
  install_shell
  managed="$TEST_TMPDIR/account/.config/vm-init/bash.sh"
  before=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_ino,s.st_mtime_ns)' "$managed")
  : > "$VM_INIT_NOTES_FILE"
  install_shell
  after=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_ino,s.st_mtime_ns)' "$managed")
  [ "$before" = "$after" ]
  [ "$(wc -l < "$TEST_TMPDIR/chsh" | tr -d ' ')" = 1 ]
  [ ! -s "$VM_INIT_NOTES_FILE" ]
  [ "$(grep -c '# vm-init' "$TEST_TMPDIR/account/.bashrc")" = 1 ]
}

@test "shell local edits survive apply and explicit restoration replaces them" {
  shell_fixture
  install_shell
  managed="$TEST_TMPDIR/account/.config/vm-init/bash.sh"
  echo 'alias custom=ls' >> "$managed"
  run install_shell
  [ "$status" -eq 0 ]
  [[ "$output" == *'configuration drift'* ]]
  grep -q custom "$managed"
  VM_INIT_RESTORE_CONFIG=1 install_shell
  ! grep -q custom "$managed"
  grep -q custom "${managed}.vm-init.bak"
}

@test "a YAML shell change removes old managed aliases and leaves other startup content intact" {
  shell_fixture
  install_shell
  echo '# administrator content' >> "$TEST_TMPDIR/account/.bashrc"
  echo 'shell: {enabled: true, default_shell: bash, aliases: {la: "ls -a"}}' > "$CONFIG"
  install_shell
  grep -q 'alias la=' "$TEST_TMPDIR/account/.config/vm-init/bash.sh"
  ! grep -q 'alias ll=' "$TEST_TMPDIR/account/.config/vm-init/bash.sh"
  grep -q 'administrator content' "$TEST_TMPDIR/account/.bashrc"
}

@test "shell retry resumes its own file write after a login-shell change failed" {
  shell_fixture
  chsh() { return 1; }
  run install_shell
  [ "$status" -ne 0 ]
  chsh() { echo "$2" > "$TEST_TMPDIR/login"; }
  run install_shell
  [ "$status" -eq 0 ]
  [[ "$output" != *'configuration drift'* ]]
  [ "$(cat "$TEST_TMPDIR/login")" = "$VM_INIT_SHELL_PATH" ]
}

@test "matching configuration is adopted without changing system files" {
  reconcile_decide test.value wanted wanted 1
  [ "$RECONCILE_ACTION" = unchanged ]
  reconcile_accept test.value wanted wanted
  [ "$(reconcile_load test.value | jq -r .observed)" = wanted ]
}

@test "three-way comparison separates YAML changes from local drift and conflicts" {
  reconcile_accept test.value original original
  reconcile_decide test.value requested original
  [ "$RECONCILE_ACTION" = apply ]
  reconcile_decide test.value original local-edit
  [ "$RECONCILE_ACTION" = drift ]
  reconcile_decide test.value requested local-edit
  [ "$RECONCILE_ACTION" = drift ]
  [ "$(reconcile_load test.value | jq -r .observed)" = original ]
}

@test "matching live settings supersede an older baseline without restoration" {
  reconcile_accept test.value original original
  reconcile_decide test.value requested requested
  [ "$RECONCILE_ACTION" = unchanged ]
}

@test "legacy mismatches are preserved while genuinely new resources initialize" {
  reconcile_decide test.legacy requested existing 1
  [ "$RECONCILE_ACTION" = drift ]
  reconcile_decide test.new requested absent 0
  [ "$RECONCILE_ACTION" = apply ]
}

@test "restoration and force authorize drift but never rewrite an equal value" {
  reconcile_accept test.value original original
  VM_INIT_RESTORE_CONFIG=1 reconcile_decide test.value requested local-edit
  [ "$RECONCILE_ACTION" = apply ]
  VM_INIT_FORCE=1 reconcile_decide test.value requested local-edit
  [ "$RECONCILE_ACTION" = apply ]
  VM_INIT_FORCE=1 reconcile_decide test.value requested requested
  [ "$RECONCILE_ACTION" = unchanged ]
}

@test "read-only inspection neither initializes nor advances a baseline" {
  VM_INIT_DRY_RUN=1 reconcile_accept test.value wanted wanted
  [ ! -d "$VM_INIT_STATE_DIR" ]
  reconcile_accept test.value original original
  VM_INIT_VERIFY=1 reconcile_accept test.value requested requested
  [ "$(reconcile_load test.value | jq -r .desired)" = original ]
}

@test "an invalid baseline fails before force can authorize writes" {
  mkdir -p "$VM_INIT_STATE_DIR/baselines"
  echo broken > "$VM_INIT_STATE_DIR/baselines/test.value.json"
  VM_INIT_FORCE=1 run reconcile_decide test.value wanted existing
  [ "$status" -ne 0 ]
  [ "$(reconcile_summary test | jq -r .configuration_state)" = unknown ]
}

@test "partial work can resume but a later administrator edit stays protected" {
  reconcile_accept test.value original original
  reconcile_begin test.value requested original
  reconcile_checkpoint test.value partial
  reconcile_decide test.value requested partial
  [ "$RECONCILE_ACTION" = apply ]
  reconcile_decide test.value requested local-edit
  [ "$RECONCILE_ACTION" = drift ]
}

@test "file reconciliation preserves inode and timestamp on a second apply" {
  printf 'wanted\n' > "$TEST_TMPDIR/source"
  reconcile_file test.file "$TEST_TMPDIR/source" "$TEST_TMPDIR/destination"
  before=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_ino,s.st_mtime_ns)' "$TEST_TMPDIR/destination")
  reconcile_file test.file "$TEST_TMPDIR/source" "$TEST_TMPDIR/destination"
  after=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_ino,s.st_mtime_ns)' "$TEST_TMPDIR/destination")
  [ "$before" = "$after" ]
}

@test "file drift preserves bytes and scoped restoration retains a backup" {
  echo desired > "$TEST_TMPDIR/source"
  reconcile_file test.file "$TEST_TMPDIR/source" "$TEST_TMPDIR/destination"
  echo custom > "$TEST_TMPDIR/destination"
  run reconcile_file test.file "$TEST_TMPDIR/source" "$TEST_TMPDIR/destination"
  [ "$status" -eq 2 ]
  [ "$(cat "$TEST_TMPDIR/destination")" = custom ]
  VM_INIT_RESTORE_CONFIG=1 reconcile_file test.file "$TEST_TMPDIR/source" "$TEST_TMPDIR/destination"
  [ "$(cat "$TEST_TMPDIR/destination")" = desired ]
  [ "$(cat "$VM_INIT_STATE_DIR/baselines/test.file.test-run.bak")" = custom ]
}

@test "healthy enabled services receive no mutations and stopped services start once" {
  echo active > "$TEST_TMPDIR/runtime"
  systemctl() {
    case "$1" in
      is-enabled) echo enabled ;;
      is-active) [ "$(cat "$TEST_TMPDIR/runtime")" = active ] ;;
      start) echo "$*" >> "$TEST_TMPDIR/mutations"; echo active > "$TEST_TMPDIR/runtime" ;;
      *) echo "$*" >> "$TEST_TMPDIR/mutations" ;;
    esac
  }
  run_quiet() { "$@"; }
  reconcile_service test example
  [ ! -e "$TEST_TMPDIR/mutations" ]
  echo stopped > "$TEST_TMPDIR/runtime"
  reconcile_service test example
  [ "$(cat "$TEST_TMPDIR/mutations")" = 'start example' ]
}

@test "disabled managed services are preserved as drift" {
  reconcile_accept test.service.example enabled enabled
  systemctl() { if [[ "$1" = is-enabled ]]; then echo disabled; return 1; fi; touch "$TEST_TMPDIR/mutation"; }
  run reconcile_service test example 1
  [ "$status" -eq 2 ]
  [ ! -e "$TEST_TMPDIR/mutation" ]
}

@test "summary retains changes when a resource is subsequently checked again" {
  reconcile_report test.value in_sync desired desired verified true
  reconcile_report test.value in_sync desired desired verified false
  [ "$(reconcile_summary test | jq -r .changed)" = true ]
}

@test "configuration reports keep resource labels and filter summaries by module" {
  VM_INIT_RESOURCE_LABEL='Shell settings for Alice' reconcile_report test.value drifted desired local-edit 'local change'
  VM_INIT_CURRENT_MODULE=other reconcile_report other.value unknown expected unavailable 'cannot inspect'
  jq -es 'map(select(.module == "test")) | length == 1 and
    .[0].label == "Shell settings for Alice" and .[0].resource == "test.value"' "$VM_INIT_RECONCILE_REPORT"
  run reconcile_summary test
  [ "$status" -eq 0 ]
  jq -e '.configuration_state == "drifted" and .changed == false and .differences ==
    [{resource:"Shell settings for Alice",expected:"desired",observed:"local-edit",reason:"local change"}]' <<< "$output"
}

@test "unchanged firewall avoids snapshots timers rules and reloads over SSH" {
  source "$VM_INIT_REPO_ROOT/modules/ufw.sh"
  export CONFIG="$TEST_TMPDIR/config.yml" SSH_CONNECTION='198.51.100.1 4000 192.0.2.1 22'
  echo 'ufw: {enabled: true, allow: [OpenSSH]}' > "$CONFIG"
  require_commands() { return 0; }
  is_installed() { return 0; }
  ufw_lock() { return 0; }
  ufw_config_matches() { return 0; }
  ufw() { [[ "$1 $2" == 'show added' ]] || { echo unexpected; return 1; }; }
  snapshot_paths() { touch "$TEST_TMPDIR/snapshot"; }
  ufw_schedule_rollback() { touch "$TEST_TMPDIR/timer"; }
  run install_ufw
  [ "$status" -eq 0 ]
  [[ "$output" == *'Firewall unchanged'* ]]
  [ ! -e "$TEST_TMPDIR/snapshot" ]
  [ ! -e "$TEST_TMPDIR/timer" ]
  ! grep -q 'confirm firewall' "$VM_INIT_NOTES_FILE" 2>/dev/null
}

@test "firewall profiles and explicit ports compare equally without retiring the owned rule" {
  source "$VM_INIT_REPO_ROOT/modules/ufw.sh"
  ufw() { [[ "$*" = 'app info OpenSSH' ]] || return 1; printf 'Profile: OpenSSH\nPort:\n  22/tcp\n'; }
  run ufw_rule_present OpenSSH '22/tcp  ALLOW IN  Anywhere' 4
  [ "$status" -eq 0 ]
  run ufw_stale_rule_numbers 22/tcp '[ 1] OpenSSH  ALLOW IN  Anywhere # vm-init'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run ufw_stale_rule_numbers OpenSSH '[ 1] 22/tcp  ALLOW IN  Anywhere # vm-init'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "restoration options are present in retry commands and saved retry loading" {
  source "$VM_INIT_REPO_ROOT/modules/_actions.sh"
  export CONFIG="$TEST_TMPDIR/config with spaces.yml" VM_INIT_EXECUTABLE=/usr/local/bin/vm-init
  export VM_INIT_TARGET_USERS='alice bob' VM_INIT_NO_UPGRADE=1 VM_INIT_RESTORE_CONFIG=1
  echo '{}' > "$CONFIG"
  run retry_command apply shell
  [ "$status" -eq 0 ]
  [[ "$output" == *--restore-config* ]]
  state_set last.config "$CONFIG"
  state_set last.failed shell
  state_set last.restore_config 1
  VM_INIT_RESTORE_CONFIG=0
  load_failed_run
  [ "$VM_INIT_RESTORE_CONFIG" = 1 ]
}

@test "repository adoption avoids downloads and repository drift requires restoration" {
  export VM_INIT_CURRENT_MODULE=yazi
  list="$TEST_TMPDIR/repository.list"; keyring="$TEST_TMPDIR/key.gpg"
  echo 'deb https://packages.example.invalid stable main' > "$list"
  echo key > "$keyring"
  gpg() { return 0; }
  apt_get() { echo "$*" >> "$TEST_TMPDIR/apt"; }
  run_quiet() { "$@"; }
  download_file() { touch "$TEST_TMPDIR/download"; return 1; }
  reconcile_repository yazi "$list" "$keyring" https://example.invalid/key 'deb https://packages.example.invalid stable main'
  [ ! -e "$TEST_TMPDIR/download" ]
  [ ! -e "$TEST_TMPDIR/apt" ]
  echo 'deb https://local.example.invalid stable main' > "$list"
  run reconcile_repository yazi "$list" "$keyring" https://example.invalid/key 'deb https://packages.example.invalid stable main'
  [ "$status" -eq 2 ]
  grep -q local.example "$list"
  VM_INIT_RESTORE_CONFIG=1 reconcile_repository yazi "$list" "$keyring" https://example.invalid/key 'deb https://packages.example.invalid stable main'
  grep -q packages.example "$list"
  [ ! -e "$TEST_TMPDIR/download" ]
  [ "$(cat "$TEST_TMPDIR/apt")" = 'update -q' ]
}

@test "Fail2ban effective policy handles normalized networks and protects runtime drift" {
  source "$VM_INIT_REPO_ROOT/modules/fail2ban.sh"
  export VM_INIT_CURRENT_MODULE=fail2ban VM_INIT_FAIL2BAN_ROOT="$TEST_TMPDIR/system" CONFIG="$TEST_TMPDIR/fail2ban.yml"
  echo 'fail2ban: {enabled: true, bantime: 3600, findtime: 600, maxretry: 5, backend: systemd, banaction: ufw, jails: {sshd: {enabled: true}}}' > "$CONFIG"
  mkdir -p "$VM_INIT_FAIL2BAN_ROOT/etc/fail2ban/jail.d"
  destination="$VM_INIT_FAIL2BAN_ROOT/etc/fail2ban/jail.d/vm-init.local"
  render_fail2ban_config > "$destination"
  echo 5 > "$TEST_TMPDIR/maxretry"
  require_commands() { return 0; }
  is_installed() { return 0; }
  run_quiet() { "$@"; }
  systemctl() {
    case "$1" in is-enabled) echo enabled ;; is-active) return 0 ;; *) echo "$*" >> "$TEST_TMPDIR/service-mutations" ;; esac
  }
  fail2ban-client() {
    case "$*" in
      'status sshd'|'get sshd journalmatch'|-t) return 0 ;;
      'get sshd bantime') echo 3600 ;;
      'get sshd findtime') echo 600 ;;
      'get sshd maxretry') cat "$TEST_TMPDIR/maxretry" ;;
      'get sshd actions') printf 'The jail sshd has the following actions:\nufw\n' ;;
      'get sshd ignoreip') printf 'These IP addresses/networks are ignored:\n|- 127.0.0.0/8\n`- ::1\n' ;;
      -d) echo "['add', 'sshd', 'systemd']" ;;
      'reload --restart') echo 5 > "$TEST_TMPDIR/maxretry" ;;
      *) return 1 ;;
    esac
  }
  install_fail2ban
  before=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_ino,s.st_mtime_ns)' "$destination")
  install_fail2ban
  after=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_ino,s.st_mtime_ns)' "$destination")
  [ "$before" = "$after" ]
  [ ! -e "$TEST_TMPDIR/service-mutations" ]
  echo 9 > "$TEST_TMPDIR/maxretry"
  run install_fail2ban
  [ "$status" -eq 0 ]
  [[ "$output" == *'configuration drift'* ]]
  [ "$(cat "$TEST_TMPDIR/maxretry")" = 9 ]
  VM_INIT_RESTORE_CONFIG=1 install_fail2ban
  [ "$(cat "$TEST_TMPDIR/maxretry")" = 5 ]
}

@test "matching DNS keeps files and services untouched and starts a stopped proxy" {
  source "$VM_INIT_REPO_ROOT/modules/dns.sh"
  export VM_INIT_CURRENT_MODULE=dns VM_INIT_DNS_ROOT="$TEST_TMPDIR/system" CONFIG="$TEST_TMPDIR/dns.yml"
  echo 'dns: {enabled: true}' > "$CONFIG"
  render_dns_config > /dev/null
  echo active > "$TEST_TMPDIR/proxy-state"
  require_commands() { return 0; }
  is_installed() { return 0; }
  run_quiet() { "$@"; }
  ip() { return 0; }
  getent() { echo '192.0.2.80 example.com'; }
  dig() { echo 192.0.2.80; }
  dnsproxy_listening_on() { return 0; }
  resolvectl() {
    case "$1" in dns) echo 'Global: 127.0.0.1:5353' ;; domain) echo 'Global: ~.' ;; *) return 1 ;; esac
  }
  systemctl() {
    case "$1" in
      is-enabled) echo enabled ;;
      is-active)
        if [[ "${*: -1}" == dnsproxy ]]; then [[ "$(cat "$TEST_TMPDIR/proxy-state")" == active ]]; fi
        ;;
      show) echo 'argv[]=/usr/local/bin/dnsproxy --upstream=https://base.dns.mullvad.net/dns-query --listen=127.0.0.1 --port=5353 --bootstrap 9.9.9.9 --bootstrap 149.112.112.112 --cache ;' ;;
      start) echo "$*" >> "$TEST_TMPDIR/service-mutations"; echo active > "$TEST_TMPDIR/proxy-state" ;;
      *) echo "$*" >> "$TEST_TMPDIR/service-mutations"; return 1 ;;
    esac
  }
  before=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_ino,s.st_mtime_ns)' "$VM_INIT_DNS_ROOT/etc/systemd/system/dnsproxy.service")
  run install_dns
  [ "$status" -eq 0 ]
  [[ "$output" == *'DNS configuration unchanged'* ]]
  [ ! -e "$TEST_TMPDIR/service-mutations" ]
  after=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_ino,s.st_mtime_ns)' "$VM_INIT_DNS_ROOT/etc/systemd/system/dnsproxy.service")
  [ "$before" = "$after" ]
  echo stopped > "$TEST_TMPDIR/proxy-state"
  run install_dns
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_TMPDIR/service-mutations")" = 'start dnsproxy' ]
  [ ! -d "$VM_INIT_STATE_DIR/dns-original" ]
}

@test "Docker repository drift does not block independent account configuration" {
  source "$VM_INIT_REPO_ROOT/modules/docker.sh"
  export VM_INIT_CURRENT_MODULE=docker VM_INIT_TARGET_USERS=alice
  require_commands() { return 0; }
  ensure_apt_packages() { return 0; }
  docker_repository() { return 2; }
  is_installed() { return 0; }
  apt_install_group_with_report() { touch "$TEST_TMPDIR/unexpected-package-update"; }
  getent() { echo 'alice:x:1000:1000::/home/alice:/bin/bash'; }
  id() { if [[ -f "$TEST_TMPDIR/group" ]]; then echo 'alice docker'; else echo alice; fi; }
  usermod() { echo "$*" > "$TEST_TMPDIR/group"; }
  reconcile_service() { echo "$*" > "$TEST_TMPDIR/service-check"; }
  install_docker
  [ ! -e "$TEST_TMPDIR/unexpected-package-update" ]
  [ "$(cat "$TEST_TMPDIR/group")" = '-aG docker alice' ]
  [ -e "$TEST_TMPDIR/service-check" ]
}
