#!/usr/bin/env bats

setup() {
  load '../test_helper.bash'
  make_test_tmpdir
  load_common
  CONFIG="$TEST_TMPDIR/config.yml"
}

teardown() { cleanup_test_tmpdir; }

@test "configuration accepts ordinary strings with jq 1.6 and newer" {
  cp "$VM_INIT_DEFAULT_CONFIG" "$CONFIG"
  run validate_config_schema
  [ "$status" -eq 0 ]
}

@test "configuration rejects escaped NUL and line breaks" {
  for escape in '\u0000' '\n' '\r'; do
    printf 'shell: {aliases: {ll: "ls%s-l"}}\n' "$escape" > "$CONFIG"
    run validate_config_schema
    [ "$status" -eq 1 ]
    [[ "$output" == *'must not contain line breaks or NUL characters'* ]]
  done
}

@test "parser bootstrap rejects a corrupted download before installation" {
  uname() { echo x86_64; }
  download_file() { printf 'corrupted download\n' > "$2"; }
  install() { touch "$TEST_TMPDIR/installed"; }
  run install_config_yq
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_TMPDIR/installed" ]
}

mock_accounts() {
  getent() {
    case "${2:-}" in
      root) echo 'root:x:0:0:root:/root:/bin/bash' ;;
      alice) echo 'alice:x:1000:1000::/home/alice:/bin/bash' ;;
      bob) echo 'bob:x:1001:1001::/srv/bob:/bin/bash' ;;
      '') printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' 'alice:x:1000:1000::/home/alice:/bin/bash' 'bob:x:1001:1001::/srv/bob:/bin/bash' 'daemon:x:1002:1002::/srv/daemon:/usr/sbin/nologin' ;;
      *) return 2 ;;
    esac
  }
}

@test "account selection prioritizes CLI then YAML then sudo user and root" {
  mock_accounts
  echo 'users: [bob]' > "$CONFIG"
  SUDO_USER=alice VM_INIT_USER_OPTION=root
  resolve_target_users
  [ "$VM_INIT_TARGET_USERS" = root ]
  VM_INIT_USER_OPTION=''
  resolve_target_users
  [ "$VM_INIT_TARGET_USERS" = bob ]
  echo '{}' > "$CONFIG"
  resolve_target_users
  [ "$VM_INIT_TARGET_USERS" = alice ]
  unset SUDO_USER
  id() { echo root; }
  resolve_target_users
  [ "$VM_INIT_TARGET_USERS" = root ]
}

@test "selected users are deduplicated and all-users excludes non-login accounts" {
  mock_accounts
  echo '{}' > "$CONFIG"
  VM_INIT_USER_OPTION='root,alice,root,bob'
  resolve_target_users
  [ "$VM_INIT_TARGET_USERS" = 'root alice bob' ]
  VM_INIT_USER_OPTION='' VM_INIT_ALL_USERS=1
  resolve_target_users
  [ "$VM_INIT_TARGET_USERS" = 'root alice bob' ]
}

@test "account resolution rejects nonexistent accounts" {
  mock_accounts
  echo '{}' > "$CONFIG"
  VM_INIT_USER_OPTION='root,missing'
  run resolve_target_users
  [ "$status" -ne 0 ]
  [[ "$output" == *'Account does not exist: missing'* ]]
}

@test "account names never expand as filesystem globs" {
  mock_accounts
  echo '{}' > "$CONFIG"
  mkdir "$TEST_TMPDIR/names"
  touch "$TEST_TMPDIR/names/root"
  cd "$TEST_TMPDIR/names"
  VM_INIT_USER_OPTION='*'
  run resolve_target_users
  [ "$status" -ne 0 ]
  [[ "$output" == *'Invalid account name: *'* ]]
}
