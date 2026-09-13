#!/usr/bin/env bats

setup() {
  load '../test_helper.bash'
  make_test_tmpdir
  [[ "$EUID" == 0 && -f /etc/os-release ]] || skip 'requires root on Ubuntu'
  export VM_INIT_MIN_DISK_MB=0 VM_INIT_UPDATE_CHECK=0
  fixture="$TEST_TMPDIR/checkout"
  mkdir -p "$fixture"
  cp "$VM_INIT_SH" "$VM_INIT_REPO_ROOT/VERSION" "$fixture/"
  cp -R "$VM_INIT_REPO_ROOT/modules" "$VM_INIT_REPO_ROOT/scripts" "$fixture/"
  # No system modules are enabled: exercise the real lifecycle in isolation.
  printf 'apt: {enabled: false}\nshell: {enabled: false}\n' > "$fixture/vm-init.yml"
  cd "$TEST_TMPDIR"
}

teardown() { cleanup_test_tmpdir; }

@test "first normal root run saves configuration and repeat runs need no wizard" {
  run env -u SUDO_USER "$fixture/vm-init.sh" --yes --no-log
  [ "$status" -eq 0 ]
  [[ "$output" == *'Setup choices: accounts root'* ]]
  jq -e '.users == ["root"]' "$VM_INIT_PREFIX/config/vm-init.yml"
  [ "$(stat -c %a "$VM_INIT_PREFIX/config/vm-init.yml")" = 600 ]
  before=$(sha256sum "$VM_INIT_PREFIX/config/vm-init.yml")
  run "$fixture/vm-init.sh" --no-log
  [ "$status" -eq 0 ]
  [[ "$output" != *'Setup choices:'* ]]
  [ "$(sha256sum "$VM_INIT_PREFIX/config/vm-init.yml")" = "$before" ]
}

@test "noninteractive initialization without yes fails before persistent writes" {
  run "$fixture/vm-init.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *'needs a terminal'* ]]
  [ ! -d "$VM_INIT_PREFIX" ]
  [ ! -d "$VM_INIT_STATE_DIR" ]
}

@test "normal execution prepares tools before the wizard and previews never prepare" {
  cat >> "$fixture/modules/_config.sh" <<'SH'
bootstrap_config_tools() { touch "$TEST_TMPDIR/prepared"; }
check_config_tools() { [[ -f "$TEST_TMPDIR/prepared" ]]; }
SH
  run "$fixture/vm-init.sh" plan
  [ "$status" -ne 0 ]
  [ ! -f "$TEST_TMPDIR/prepared" ]
  [ ! -d "$VM_INIT_PREFIX" ]
  run "$fixture/vm-init.sh" --yes --no-log
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/prepared" ]
  [ -f "$VM_INIT_PREFIX/config/vm-init.yml" ]
}

@test "explicit configuration applies unattended without replacing saved configuration" {
  mkdir -p "$VM_INIT_PREFIX/config"
  echo '{"users":["root"]}' > "$VM_INIT_PREFIX/config/vm-init.yml"
  echo '{}' > "$TEST_TMPDIR/team.yml"
  run "$fixture/vm-init.sh" --config "$TEST_TMPDIR/team.yml" --no-log
  [ "$status" -eq 0 ]
  [[ "$output" != *'Setup choices:'* ]]
  [ "$(cat "$VM_INIT_PREFIX/config/vm-init.yml")" = '{"users":["root"]}' ]
}

@test "cancelled guided configuration saves nothing and applies no modules" {
  run bash -c 'printf "\n\nn\n" | script -qec "$1 --no-log" /dev/null' _ "$fixture/vm-init.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Setup cancelled'* ]]
  [ ! -f "$VM_INIT_PREFIX/config/vm-init.yml" ]
  [ ! -d "$VM_INIT_STATE_DIR/runs" ]
}

@test "bundle installs itself and works after its downloaded copy is removed" {
  bash "$fixture/scripts/build-single.sh" "$TEST_TMPDIR/download" >/dev/null
  bundle="$TEST_TMPDIR/download/vm-init-$(cat "$fixture/VERSION")"
  run "$bundle" --yes --no-log
  [ "$status" -eq 0 ]
  [ -x "$VM_INIT_PREFIX/app/vm-init" ]
  [ -x "$VM_INIT_BIN_DIR/vm-init" ]
  [ ! -d "$VM_INIT_PREFIX/app/modules" ]
  rm -rf "$TEST_TMPDIR/download"
  run env -u VM_INIT_PREFIX -u VM_INIT_BIN_DIR "$VM_INIT_BIN_DIR/vm-init" status
  [ "$status" -eq 0 ]
  [[ "$output" == *'saved configuration'* ]]
}

@test "downloaded bundle delegates to an existing installed command without replacing it" {
  mkdir -p "$VM_INIT_PREFIX/bin"
  cat > "$VM_INIT_PREFIX/bin/vm-init" <<'SH'
#!/usr/bin/env bash
printf 'delegated:%s\n' "$*"
[[ -z "${VM_INIT_BUNDLED:-}" ]]
SH
  chmod +x "$VM_INIT_PREFIX/bin/vm-init"
  bash "$fixture/scripts/build-single.sh" "$TEST_TMPDIR/download" >/dev/null
  bundle="$TEST_TMPDIR/download/vm-init-$(cat "$fixture/VERSION")"
  run "$bundle" --yes --user root
  [ "$status" -eq 0 ]
  [[ "$output" == *'delegated:--yes --user root'* ]]
  [ ! -d "$VM_INIT_PREFIX/app" ]
}

@test "saved configuration takes precedence over the working directory" {
  mkdir -p "$VM_INIT_PREFIX/config"
  echo '{}' > "$VM_INIT_PREFIX/config/vm-init.yml"
  echo 'invalid: [' > "$TEST_TMPDIR/vm-init.yml"
  run "$fixture/vm-init.sh" plan
  [ "$status" -eq 0 ]
  [[ "$output" == *'saved configuration'* ]]
}

@test "first-run preparation failure saves no configuration or run context" {
  echo 'bootstrap_config_tools() { return 1; }' >> "$fixture/modules/_config.sh"
  run "$fixture/vm-init.sh" --yes --no-log
  [ "$status" -ne 0 ]
  [ ! -f "$VM_INIT_PREFIX/config/vm-init.yml" ]
  [ ! -d "$VM_INIT_STATE_DIR/runs" ]
}

@test "a flat managed installation moves code and retains its old configuration and recovery entry points" {
  mkdir -p "$VM_INIT_PREFIX"
  cp -a "$fixture/." "$VM_INIT_PREFIX/"
  printf '%s\n0\n' "$VM_INIT_BIN_DIR" > "$VM_INIT_PREFIX/.vm-init-managed"
  before=$(sha256sum "$VM_INIT_PREFIX/vm-init.yml" | cut -d' ' -f1)
  run "$VM_INIT_PREFIX/vm-init.sh" --no-log
  [ "$status" -eq 0 ]
  [[ "$output" != *'Setup choices:'* ]]
  [ -L "$VM_INIT_PREFIX/vm-init.sh" ]
  [ -L "$VM_INIT_PREFIX/modules" ]
  [ "$(readlink "$VM_INIT_PREFIX/vm-init.yml")" = config/vm-init.yml ]
  [ "$(sha256sum "$VM_INIT_PREFIX/config/vm-init.yml" | cut -d' ' -f1)" = "$before" ]
  run "$VM_INIT_PREFIX/modules/recover-dns.sh" --help
  [ "$status" -eq 0 ]
  run "$VM_INIT_BIN_DIR/vm-init" --no-log
  [ "$status" -eq 0 ]
}

@test "reconfiguration preserves unrelated settings and backs up the previous configuration" {
  mkdir -p "$VM_INIT_PREFIX/config"
  echo '{"users":["root"],"apt":{"enabled":false},"dns":{"enabled":false,"server":"https://example.com/dns-query"}}' > "$VM_INIT_PREFIX/config/vm-init.yml"
  run "$fixture/vm-init.sh" setup --yes --no-log
  [ "$status" -eq 0 ]
  jq -e '.dns.server == "https://example.com/dns-query" and .apt.enabled == false' "$VM_INIT_PREFIX/config/vm-init.yml"
  backups=("$VM_INIT_PREFIX/config/"*.bak)
  [ -f "${backups[0]}" ]
}

@test "unreadable saved configuration never falls back to a local file" {
  mkdir -p "$VM_INIT_PREFIX/config"
  echo '{}' > "$VM_INIT_PREFIX/config/vm-init.yml"
  chmod 0700 "$VM_INIT_PREFIX/config"
  chmod 0755 "$TEST_TMPDIR"
  echo '{}' > "$TEST_TMPDIR/vm-init.yml"
  run sudo -u nobody env VM_INIT_PREFIX="$VM_INIT_PREFIX" VM_INIT_UPDATE_CHECK=0 "$fixture/vm-init.sh" plan
  [ "$status" -ne 0 ]
  [[ "$output" == *'Cannot read configuration directory'* ]]
}

@test "one configuration writes shell files owned by root and both selected accounts" {
  local alice="vm-init-alice-$BATS_TEST_NUMBER" bob="vm-init-bob-$BATS_TEST_NUMBER"
  chmod 0755 "$TEST_TMPDIR"
  useradd --create-home --home-dir "$TEST_TMPDIR/alice" "$alice"
  useradd --create-home --home-dir "$TEST_TMPDIR/bob" "$bob"
  cat > "$fixture/vm-init.yml" <<'YAML'
apt: {enabled: false}
shell:
  enabled: true
  default_shell: bash
  fisher: false
  tide: false
  zoxide: false
  direnv: false
  aliases: {ll: "ls -al"}
YAML
  run "$fixture/vm-init.sh" --yes --no-log -U root --user "$alice,$bob" -U root
  [ "$status" -eq 0 ]
  jq -e --arg alice "$alice" --arg bob "$bob" '.users == ["root", $alice, $bob]' "$VM_INIT_PREFIX/config/vm-init.yml"
  [ "$(stat -c %U /root/.config/vm-init/bash.sh)" = root ]
  [ "$(stat -c %U "$TEST_TMPDIR/alice/.config/vm-init/bash.sh")" = "$alice" ]
  [ "$(stat -c %U "$TEST_TMPDIR/bob/.config/vm-init/bash.sh")" = "$bob" ]
  for action in status --status -s --verify; do
    run "$fixture/vm-init.sh" "$action" --no-log
    [ "$status" -eq 0 ]
  done
}
