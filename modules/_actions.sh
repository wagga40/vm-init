#!/usr/bin/env bash
# Friendly command entry points. Existing flags use the same execution path.

retry_command() {
  local mode="$1" modules="${2:-}" config="${VM_INIT_RETRY_CONFIG:-${VM_INIT_SOURCE_CONFIG:-$CONFIG}}"
  local args=(sudo "$VM_INIT_EXECUTABLE")
  if [[ "$mode" == status ]]; then args+=(status); else args+=(apply); fi
  if [[ -n "$config" && "$config" != "${VM_INIT_EMBEDDED_CONFIG_TMP:-}" ]]; then args+=(--config "$config"); fi
  [[ -z "$modules" ]] || args+=(--only "$modules")
  if [[ -n "${VM_INIT_TARGET_USERS:-}" ]]; then args+=(--user "${VM_INIT_TARGET_USERS// /,}"); fi
  if [[ "$mode" != status ]]; then
    [[ "$VM_INIT_FORCE" != 1 ]] || args+=(--force)
    [[ "${VM_INIT_RESTORE_CONFIG:-0}" != 1 ]] || args+=(--restore-config)
    [[ "$VM_INIT_NO_UPGRADE" != 1 ]] || args+=(--no-upgrade)
    args+=(--verbose)
  fi
  shell_command "${args[@]}"
}

load_failed_run() {
  local config failed
  config=$(state_get last.config) || { log_fail 'No saved run to retry'; return 1; }
  failed=$(state_get last.failed) || { log_fail 'The last run has no failed modules'; return 1; }
  [[ -f "$config" ]] || { log_fail 'The saved configuration is missing'; return 1; }
  CONFIG="$config"
  CONFIG_EXPLICIT=1
  export VM_INIT_CONFIG_ORIGIN='saved run configuration'
  export VM_INIT_ONLY="$failed"
  VM_INIT_FORCE=$(state_get last.force 2>/dev/null || echo 0)
  if [[ "${VM_INIT_RESTORE_CONFIG:-0}" != 1 ]]; then VM_INIT_RESTORE_CONFIG=$(state_get last.restore_config 2>/dev/null || echo 0); fi
  VM_INIT_NO_UPGRADE=$(state_get last.no_upgrade 2>/dev/null || echo 0)
}

setup_wizard() {
  check_config_tools || return 1
  local account="${VM_INIT_USER_OPTION:-${SUDO_USER:-}}" features="${VM_INIT_FEATURES:-}" answer json users
  local choices=()
  if [[ "${VM_INIT_ALL_USERS:-0}" == 1 ]]; then
    account="root$(human_users | cut -d: -f1 | while read -r user; do printf ',%s' "$user"; done)"
  fi
  if [[ "$account" == root && -z "${VM_INIT_USER_OPTION:-}" && "${VM_INIT_ALL_USERS:-0}" != 1 ]]; then account=""; fi
  if [[ -z "$account" && $EUID -ne 0 ]]; then account=$(id -un); fi
  if [[ "${VM_INIT_YES:-0}" != 1 && "${VM_INIT_DRY_RUN:-0}" != 1 ]]; then
    if [[ ! -t 0 ]]; then
      log_fail 'Interactive setup needs a terminal. For automation use setup --yes --user <name> --features shell,docker.'
      return 1
    fi
    printf 'Set up this machine\n\n'
    printf 'Account%s: ' "${account:+ [$account]}"
    read -r answer || return 1
    account="${answer:-$account}"
    printf 'Features: shell, docker, python, tools\nChoose a comma-separated list [shell]: '
    read -r answer || return 1
    features="${answer:-shell}"
  fi
  [[ -n "$account" ]] || { log_fail 'Choose the target account with --user <name>'; return 1; }
  features="${features:-shell}"
  case ",$features," in *,,*) log_fail 'Feature names must not be empty'; return 1 ;; esac
  local feature
  IFS=',' read -ra choices <<< "$features"
  for feature in "${choices[@]}"; do
    case "$feature" in shell|docker|python|tools) ;; *) log_fail "Unknown feature: $feature (use shell,docker,python,tools)"; return 1 ;; esac
  done
  VM_INIT_USER_OPTION="$account"
  users=$(printf '%s' "$account" | jq -R 'split(",")')
  json=$(_emit_default_config | yq -r '@json') || return 1
  VM_INIT_SETUP_TMP=$(mktemp) || return 1
  jq --argjson users "$users" --arg features ",$features," '
    .users = $users |
    .shell.enabled = ($features | contains(",shell,")) |
    .docker.enabled = ($features | contains(",docker,")) |
    .python.enabled = ($features | contains(",python,")) |
    .github_releases.enabled = ($features | contains(",tools,")) |
    if .shell.enabled then . else .apt.packages.shell = [] end |
    if .python.enabled then . else .apt.packages.python = [] end
  ' <<< "$json" > "$VM_INIT_SETUP_TMP" || return 1
  VM_INIT_SETUP_DEST="${CONFIG}"
  if [[ "$CONFIG_EXPLICIT" != 1 ]]; then VM_INIT_SETUP_DEST=/etc/vm-init/vm-init.yml; fi
  CONFIG="$VM_INIT_SETUP_TMP"
  CONFIG_EXPLICIT=1
  export VM_INIT_CONFIG_ORIGIN='setup choices'
  log_info "Setup choices: accounts ${account}; features ${features}"
}

# Resolve versions from the local APT cache without refreshing it. Apply may
# discover newer candidates; a plan never claims an unfetched version is exact.
plan_apt_packages() {
  command -v dpkg-query >/dev/null && command -v apt-cache >/dev/null || return 0
  local package installed candidate action
  for package in "$@"; do
    installed=$(apt_installed_version "$package")
    candidate=$(apt-cache policy "$package" 2>/dev/null | awk '/Candidate:/ { print $2; exit }' || true)
    action=install
    if [[ -n "$installed" ]]; then
      if should_force; then action=reinstall
      elif ! should_upgrade || [[ "$candidate" == "$installed" ]]; then action=keep
      else action=upgrade; fi
    fi
    printf '    %-22s %-10s installed: %-14s cached candidate: %s\n' "$package" "$action" "${installed:-none}" "${candidate:-unknown}"
  done
  printf '    Versions above use the local cache; apply may refresh it and resolve dependencies.\n'
}

confirm_setup_plan() {
  [[ "${VM_INIT_SETUP:-0}" == 1 && "$VM_INIT_DRY_RUN" != 1 ]] || return 0
  local spec section module_file entry_func answer
  echo 'Preview changes'
  for spec in "${VM_INIT_MODULES[@]}"; do
    section="${spec%%:*}"
    if ! module_excluded "$section" && [[ "$(yq_get ".${section}.enabled" false "$CONFIG")" == true ]]; then
      IFS=: read -r section module_file entry_func <<< "$spec"
      source_module "$module_file" "$entry_func"
      dry_run_preview "$section"
    fi
  done
  printf '\nSave configuration to: %s\n' "$VM_INIT_SETUP_DEST"
  if [[ "${VM_INIT_YES:-0}" != 1 ]]; then
    printf 'Apply these changes? [y/N]: '
    read -r answer || return 1
    case "$answer" in y|Y|yes) ;; *) log_info 'Setup cancelled; no changes applied'; return 2 ;; esac
  fi
  # The configuration is only persisted after the user has reviewed the plan.
  if [[ -f "$VM_INIT_SETUP_DEST" ]]; then
    cp -p "$VM_INIT_SETUP_DEST" "${VM_INIT_SETUP_DEST}.${VM_INIT_RUN_ID}.bak" || return 1
  fi
  install -D -m 0644 "$CONFIG" "$VM_INIT_SETUP_DEST" || return 1
  VM_INIT_SOURCE_CONFIG="$VM_INIT_SETUP_DEST"
}

print_json_summary() {
  local i rows='[]' status messages
  for ((i=0; i<${#VM_INIT_MODULE_NAMES[@]}; i++)); do
    status="${VM_INIT_MODULE_STATUS[$i]}"
    rows=$(jq --arg name "${VM_INIT_MODULE_NAMES[$i]}" --arg status "$status" \
      --arg detail "${VM_INIT_MODULE_DETAIL[$i]}" --arg elapsed "${VM_INIT_MODULE_ELAPSED[$i]:-0}" \
      --arg last "$(state_get "module.${VM_INIT_MODULE_NAMES[$i]}.status" 2>/dev/null || true)" \
      --argjson configuration "$(reconcile_summary "${VM_INIT_MODULE_NAMES[$i]}")" \
      '. + [{name:$name,status:$status,detail:$detail,elapsed_seconds:($elapsed|tonumber),last_outcome:$last,
        desired_state:(if $status == "skipped" then "not_managed" else "managed" end),
        observed_state:({ok:"healthy",warned:"warnings",needs_action:"needs_action",failed:"drifted",skipped:"not_checked",not_run:"not_checked"}[$status])} + $configuration]' <<< "$rows")
  done
  messages=$(vm_init_notes | jq -Rn '[inputs | split("\t") | {kind:.[0],module:.[1],summary:.[2],message:.[3]}]')
  jq -n --arg version "$VM_INIT_VERSION" --arg run "$VM_INIT_RUN_ID" \
    --arg config "${VM_INIT_SOURCE_CONFIG:-embedded}" --arg fingerprint "${VM_INIT_CONFIG_FINGERPRINT:-}" \
    --argjson modules "$rows" --argjson messages "$messages" \
    '{schema_version:1,version:$version,run_id:$run,config:$config,config_sha256:$fingerprint,modules:$modules,messages:$messages}' >&3
  ! jq -e 'any(.[]; .status == "failed" or .status == "not_run")' <<< "$rows" >/dev/null
}
