#!/usr/bin/env bats

setup() {
  load '../test_helper.bash'
  make_test_tmpdir
  CONFIG="$TEST_TMPDIR/config with spaces.yml"
  printf 'users: [root]\napt: {enabled: true, packages: {extra: [jq]}}\n' > "$CONFIG"
}

teardown() { cleanup_test_tmpdir; }

@test "read-only modes reject all mutating early commands before dispatch" {
  for readonly in --dry-run --verify --list-modules; do
    for mutation in --update --write-default-config --prepare; do
      run "$VM_INIT_SH" "$readonly" "$mutation" --config "$CONFIG"
      [ "$status" -eq 1 ]
      [[ "$output" == *'mutually exclusive'* ]]
      [[ "$output" != *'Updating local checkout'* ]]
    done
  done
  run "$VM_INIT_SH" repair dns --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *'mutually exclusive'* ]]
}

@test "invalid booleans and module shapes fail in both plan and list modes" {
  for config in 'docker: {enabled: tru}' 'docker: {enabled: "true"}' 'shell: true' 'apt: {packages: [jq]}' 'dns: {bootstrap: 9.9.9.9}'; do
    printf '%s\n' "$config" > "$CONFIG"
    for mode in --dry-run --list-modules; do
      run "$VM_INIT_SH" "$mode" --config "$CONFIG"
      [ "$status" -ne 0 ]
      [[ "$output" == *'must be'* ]]
    done
  done
}

@test "list-modules rejects malformed and multi-document YAML" {
  for content in $'docker: [\n' $'{}\n---\n{}'; do
    printf '%s\n' "$content" > "$CONFIG"
    run "$VM_INIT_SH" --list-modules --config "$CONFIG"
    [ "$status" -ne 0 ]
    [[ "$output" == *'not valid YAML'* ]]
  done
}

@test "plan shows selected progress and collapses disabled modules" {
  run "$VM_INIT_SH" plan --config "$CONFIG"
  [ "$status" -eq 0 ]
  [[ "$output" == *'1/1'* ]]
  [[ "$output" == *'Not selected: 10 modules'* ]]
  [[ "$output" == *'planned; no changes'* ]]
  [[ "$output" != *'11/11'* ]]
}

@test "setup preview includes chosen account and feature dependencies without saving" {
  destination="$TEST_TMPDIR/new config.yml"
  run "$VM_INIT_SH" setup --dry-run --user root --features shell,docker --config "$destination"
  [ "$status" -eq 0 ]
  [[ "$output" == *'accounts root; features shell,docker'* ]]
  [[ "$output" == *'Required packages: bat,fish,zoxide'* ]]
  [ ! -e "$destination" ]
}

@test "setup rejects unknown features and ambiguous user options" {
  run "$VM_INIT_SH" setup --dry-run --user root --features shlel
  [ "$status" -ne 0 ]
  [[ "$output" == *'Unknown feature: shlel'* ]]
  run "$VM_INIT_SH" plan --user root --all-users
  [ "$status" -ne 0 ]
  [[ "$output" == *'--user and --all-users are mutually exclusive'* ]]
}

@test "bundle offers offline DNS recovery without config or yq" {
  bash "$VM_INIT_REPO_ROOT/scripts/build-single.sh" "$TEST_TMPDIR/bundle" >/dev/null
  bundle="$TEST_TMPDIR/bundle/vm-init-$(cat "$VM_INIT_REPO_ROOT/VERSION")"
  cd "$TEST_TMPDIR"
  run "$bundle" repair dns --help
  [ "$status" -eq 0 ]
  [[ "$output" == *'repair dns'* ]]
  [[ "$output" == *'--with-fallback'* ]]
}

@test "status JSON is structured and leaves diagnostics outside stdout" {
  if [[ "$EUID" != 0 || ! -f /etc/os-release ]]; then skip 'requires root on Ubuntu'; fi
  echo '{}' > "$CONFIG"
  "$VM_INIT_SH" status --json --config "$CONFIG" > "$TEST_TMPDIR/status.json" 2> "$TEST_TMPDIR/diagnostics"
  jq -e '.schema_version == 1 and (.modules | length == 11) and (.config_sha256 | length == 64)' "$TEST_TMPDIR/status.json"
  [ -s "$TEST_TMPDIR/diagnostics" ]
}

@test "repair failed resumes unfinished modules using the saved config" {
  if [[ "$EUID" != 0 || ! -f /etc/os-release ]]; then skip 'requires root on Ubuntu'; fi
  export VM_INIT_STATE_DIR="$TEST_TMPDIR/state" VM_INIT_MIN_DISK_MB=0
  export VM_INIT_STATE_FILE="$VM_INIT_STATE_DIR/state"
  fixture="$TEST_TMPDIR/app with spaces"
  mkdir -p "$fixture"
  cp "$VM_INIT_SH" "$VM_INIT_REPO_ROOT/VERSION" "$fixture/"
  cp -R "$VM_INIT_REPO_ROOT/modules" "$fixture/"
  printf 'apt: {enabled: true, packages: {}}\npython: {enabled: true, tools: []}\n' > "$CONFIG"
  echo 'install_apt() { return 1; }' > "$fixture/modules/apt.sh"
  echo 'install_python() { touch "$TEST_TMPDIR/python-ran"; }' > "$fixture/modules/python.sh"
  run "$fixture/vm-init.sh" apply --config "$CONFIG" --fail-fast --no-log
  [ "$status" -eq 1 ]
  [ ! -f "$TEST_TMPDIR/python-ran" ]
  [[ "$output" == *'Not run'* ]]
  [[ "$output" == *'not run: 1'* ]]
  [[ "$output" != *'Needs action'* ]]
  grep -qx 'last.failed=apt,python' "$VM_INIT_STATE_FILE"
  echo 'install_apt() { return 0; }' > "$fixture/modules/apt.sh"
  echo '{}' > "$CONFIG"
  run "$fixture/vm-init.sh" repair failed --no-log
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/python-ran" ]
  grep -qx 'last.failed=' "$VM_INIT_STATE_FILE"
}

@test "standalone bundle restores saved DNS without consulting yq" {
  if [[ "$EUID" != 0 || ! -f /etc/os-release ]]; then skip 'requires root on Ubuntu'; fi
  load_common
  export VM_INIT_STATE_DIR="$TEST_TMPDIR/state"
  export VM_INIT_DNS_ROOT="$TEST_TMPDIR/system"
  mkdir -p "$VM_INIT_DNS_ROOT/etc"
  echo 'nameserver 192.0.2.53' > "$VM_INIT_DNS_ROOT/etc/resolv.conf"
  snapshot_paths "$VM_INIT_STATE_DIR/dns-original" "$VM_INIT_DNS_ROOT/etc/resolv.conf"
  printf 'systemd-resolved 0 0\n' > "$VM_INIT_STATE_DIR/dns-original/services"
  touch "$VM_INIT_STATE_DIR/dns-original/links"
  echo broken > "$VM_INIT_DNS_ROOT/etc/resolv.conf"
  stub_bin systemctl 0
  stub_bin getent 0
  cat > "$TEST_TMPDIR/bin/yq" <<'SH'
#!/usr/bin/env bash
touch "$TEST_TMPDIR/yq-was-called"
exit 1
SH
  chmod +x "$TEST_TMPDIR/bin/yq"
  bash "$VM_INIT_REPO_ROOT/scripts/build-single.sh" "$TEST_TMPDIR/bundle" >/dev/null
  bundle="$TEST_TMPDIR/bundle/vm-init-$(cat "$VM_INIT_REPO_ROOT/VERSION")"
  cd "$TEST_TMPDIR"
  run "$bundle" repair dns
  [ "$status" -eq 0 ]
  [ "$(cat "$VM_INIT_DNS_ROOT/etc/resolv.conf")" = 'nameserver 192.0.2.53' ]
  [ ! -f "$TEST_TMPDIR/yq-was-called" ]
}
