#!/usr/bin/env bats

setup() {
  load '../test_helper.bash'
  make_test_tmpdir
  echo '{}' > "$TEST_TMPDIR/config.yml"
  bash "$VM_INIT_REPO_ROOT/scripts/build-single.sh" "$TEST_TMPDIR/bundle" >/dev/null
  bundle="$TEST_TMPDIR/bundle/vm-init-$(cat "$VM_INIT_REPO_ROOT/VERSION")"
}

teardown() { cleanup_test_tmpdir; }

@test "command long and short aliases dispatch identically in checkout and bundle" {
  for executable in "$VM_INIT_SH" "$bundle"; do
    for action in help --help -h; do
      run "$executable" "$action"
      [ "$status" -eq 0 ]
      [[ "$output" == *'Usage:'* && "$output" == *'--plan -p'* ]]
    done
    for action in version --version -V; do
      run "$executable" "$action"
      [ "$status" -eq 0 ]
      [ "$output" = "vm-init $(cat "$VM_INIT_REPO_ROOT/VERSION")" ]
    done
    for action in plan --plan -p --dry-run; do
      run "$executable" -c "$TEST_TMPDIR/config.yml" "$action" --no-log
      [ "$status" -eq 0 ]
      [[ "$output" == *'Dry run complete'* ]]
    done
    for action in list-modules --list-modules -l; do
      run "$executable" "$action" -c "$TEST_TMPDIR/config.yml"
      [ "$status" -eq 0 ]
      [[ "$output" == *'disabled in config'* ]]
    done
  done
  [ ! -d "$VM_INIT_PREFIX" ]
  [ ! -d "$VM_INIT_STATE_DIR" ]
}

@test "all mutating action aliases reject conflicting previews before writes" {
  for executable in "$VM_INIT_SH" "$bundle"; do
    for action in run --run apply --apply -a update --update -u prepare --prepare -P confirm-firewall --confirm-firewall -F write-default-config --write-default-config -w; do
      run "$executable" -p "$action"
      [ "$status" -ne 0 ]
      [[ "$output" == *'mutually exclusive'* ]]
    done
    for action in repair --repair -r; do
      run "$executable" "$action" dns -p
      [ "$status" -ne 0 ]
      [[ "$output" == *'mutually exclusive'* ]]
    done
    run "$executable" apply --update
    [ "$status" -ne 0 ]
    [[ "$output" == *'mutually exclusive'* ]]
  done
  [ ! -d "$VM_INIT_PREFIX" ]
  [ ! -d "$VM_INIT_STATE_DIR" ]
}

@test "setup aliases preview repeated account selections without saving" {
  for executable in "$VM_INIT_SH" "$bundle"; do
    for action in setup --setup -S; do
      run "$executable" -U root "$action" -p --user root --features shell
      [ "$status" -eq 0 ]
      [[ "$output" == *'accounts root; features shell'* ]]
      [[ "$output" != *'accounts root,root'* ]]
    done
  done
  [ ! -d "$VM_INIT_PREFIX" ]
}

@test "all export aliases write the default and refuse to overwrite it" {
  for action in write-default-config --write-default-config -w; do
    directory="$TEST_TMPDIR/$action"
    mkdir -p "$directory"
    cd "$directory"
    run "$bundle" "$action"
    [ "$status" -eq 0 ]
    cmp vm-init.yml "$VM_INIT_DEFAULT_CONFIG"
    run "$bundle" "$action"
    [ "$status" -ne 0 ]
    [[ "$output" == *'already exists'* ]]
  done
}
