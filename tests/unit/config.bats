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
