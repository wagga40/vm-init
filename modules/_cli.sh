#!/usr/bin/env bash
# shellcheck disable=SC2034 # shared parser state
# id|aliases|description: parser and help share this action registry.
VM_INIT_ACTIONS=(
  'apply|run --run apply --apply -a|Apply saved settings; guide configuration on first run'
  'plan|plan --plan -p --dry-run|Preview without changing the machine'
  'status|status --status -s --verify|Verify selected features and configuration'
  'update|update --update -u|Update vm-init itself'
  'repair|repair --repair -r|Recover dns, or retry failed work'
  'firewall|confirm-firewall --confirm-firewall -F|Confirm firewall changes from a new SSH session'
  'list|list-modules --list-modules -l|List configured modules'
  'write|write-default-config --write-default-config -w|Export defaults to ./vm-init.yml'
  'help|help --help -h|Show help'
  'version|version --version -V|Show version'
  'setup|setup --setup -S|Reopen guided configuration (optional)'
  'prepare|prepare --prepare -P|Prepare configuration tools only (optional)'
)

cli_action() {
  local spec id aliases description alias
  for spec in "${VM_INIT_ACTIONS[@]}"; do
    IFS='|' read -r id aliases description <<< "$spec"
    for alias in $aliases; do
      if [[ "$alias" == "$1" ]]; then printf '%s\n' "$id"; return 0; fi
    done
  done
  return 1
}

cli_select_action() {
  local action="$1"
  # A setup preview remains a read-only operation.
  if [[ "$action" == setup && "${VM_INIT_COMMAND:-}" == plan ]] \
      || [[ "$action" == plan && "${VM_INIT_COMMAND:-}" == setup ]]; then
    VM_INIT_SETUP=1; VM_INIT_COMMAND=plan; return 0
  fi
  if [[ -n "${VM_INIT_COMMAND:-}" && "$VM_INIT_COMMAND" != "$action" ]]; then
    log_fail 'Execution modes are mutually exclusive; choose one command.'; return 1
  fi
  VM_INIT_COMMAND="$action"
  [[ "$action" != setup ]] || VM_INIT_SETUP=1
}

cli_action_help() {
  local spec id aliases description
  for spec in "${VM_INIT_ACTIONS[@]}"; do
    IFS='|' read -r id aliases description <<< "$spec"
    printf '  %-48s %s\n' "$aliases" "$description"
  done
}
