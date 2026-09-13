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
  local account features="${VM_INIT_FEATURES:-}" answer json users original="$CONFIG" feature template=false
  local choices=()
  case "$VM_INIT_CONFIG_ORIGIN" in 'shipped default'|'embedded default') template=true ;; esac
  VM_INIT_SETUP_DEST="$VM_INIT_CONFIG_DIR/vm-init.yml"
  [[ "$CONFIG_EXPLICIT" != 1 ]] || VM_INIT_SETUP_DEST="$original"
  if [[ -f "$original" ]]; then
    validate_config_schema || return 1
    json="$VM_INIT_CONFIG_JSON"
  else
    json=$(_emit_default_config | yq -r '@json') || return 1
  fi
  VM_INIT_SETUP_TMP=$(mktemp) || return 1
  printf '%s\n' "$json" > "$VM_INIT_SETUP_TMP"
  CONFIG="$VM_INIT_SETUP_TMP"
  resolve_target_users || return 1
  account="${VM_INIT_TARGET_USERS// /,}"
  if [[ -z "$features" ]]; then
    features=$(jq -r '[if .shell.enabled then "shell" else empty end,
      if .docker.enabled then "docker" else empty end,
      if .python.enabled then "python" else empty end,
      if .github_releases.enabled then "tools" else empty end] | join(",")' <<< "$json") || return 1
  fi
  if [[ "${VM_INIT_YES:-0}" != 1 && "${VM_INIT_DRY_RUN:-0}" != 1 ]]; then
    printf 'Set up this machine\n\nAccounts (comma-separated) [%s]: ' "$account"
    read -r answer || return 1
    account="${answer:-$account}"
    printf 'Features: shell, docker, python, tools (or none)\nChoose a comma-separated list [%s]: ' "${features:-none}"
    read -r answer || return 1
    features="${answer:-$features}"
  fi
  [[ "$features" != none ]] || features=''
  if [[ -n "$features" ]]; then
    case ",$features," in *,,*) log_fail 'Feature names must not be empty'; return 1 ;; esac
    IFS=',' read -ra choices <<< "$features"
    for feature in "${choices[@]}"; do
      case "$feature" in shell|docker|python|tools) ;; *) log_fail "Unknown feature: $feature"; return 1 ;; esac
    done
  fi
  export VM_INIT_USER_OPTION="$account"
  export VM_INIT_ALL_USERS=0
  resolve_target_users || return 1
  users=$(printf '%s' "$VM_INIT_TARGET_USERS" | jq -R 'split(" ")')
  jq --argjson users "$users" --arg features ",$features," --argjson template "$template" '
    .users = $users |
    .shell.enabled = ($features | contains(",shell,")) |
    .docker.enabled = ($features | contains(",docker,")) |
    .python.enabled = ($features | contains(",python,")) |
    .github_releases.enabled = ($features | contains(",tools,")) |
    if $template and (.shell.enabled | not) and .apt.packages.shell then .apt.packages.shell = [] else . end |
    if $template and (.python.enabled | not) and .apt.packages.python then .apt.packages.python = [] else . end
  ' <<< "$json" > "$VM_INIT_SETUP_TMP" || return 1
  CONFIG_EXPLICIT=1
  export VM_INIT_CONFIG_ORIGIN='setup choices'
  log_info "Setup choices: accounts ${VM_INIT_TARGET_USERS// /,}; features ${features:-none}"
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
    case "$answer" in y|Y|yes) ;; *) log_info 'Setup cancelled; no configuration saved or modules applied'; return 2 ;; esac
  fi
  # The configuration is only persisted after the user has reviewed the plan.
  if [[ -f "$VM_INIT_SETUP_DEST" ]]; then
    cp -p "$VM_INIT_SETUP_DEST" "${VM_INIT_SETUP_DEST}.${VM_INIT_RUN_ID}.bak" || return 1
  fi
  local destination_dir staged
  destination_dir=$(dirname "$VM_INIT_SETUP_DEST")
  (umask 077; mkdir -p "$destination_dir") || return 1
  staged=$(mktemp "$destination_dir/.vm-init-config.XXXXXX") || return 1
  if ! install -m 0600 "$CONFIG" "$staged" || ! mv -f "$staged" "$VM_INIT_SETUP_DEST"; then
    rm -f "$staged"; return 1
  fi
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
