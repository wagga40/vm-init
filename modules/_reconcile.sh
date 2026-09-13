#!/usr/bin/env bash
# Configuration baselines are data, never executable shell. All mutations run
# under run.lock (firewall confirmation additionally uses firewall.lock).

reconcile_readonly() {
  [[ "${VM_INIT_DRY_RUN:-0}" == 1 || "${VM_INIT_VERIFY:-0}" == 1 ]]
}

_sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else shasum -a 256 | awk '{print $1}'; fi
}

reconcile_path() {
  [[ "$1" =~ ^[a-zA-Z0-9_.-]+$ ]] || return 1
  printf '%s/baselines/%s.json\n' "$VM_INIT_STATE_DIR" "$1"
}

reconcile_load() {
  local path
  path=$(reconcile_path "$1") || return 1
  if [[ -d "$VM_INIT_STATE_DIR/baselines" ]] && { [[ ! -r "$VM_INIT_STATE_DIR/baselines" ]] || [[ ! -x "$VM_INIT_STATE_DIR/baselines" ]]; }; then return 1; fi
  if [[ -e "$path" || -L "$path" ]]; then
    jq -es 'if length == 1 and (.[0] | .schema_version == 1 and (.desired | type == "string") and (.observed | type == "string"))
      then .[0] else error("invalid configuration baseline") end' "$path"
  else
    printf 'null\n'
  fi
}

reconcile_save() {
  local path="$1" data="$2" temp
  mkdir -p "$VM_INIT_STATE_DIR/baselines" || return 1
  chmod 700 "$VM_INIT_STATE_DIR/baselines" || return 1
  temp=$(mktemp "$VM_INIT_STATE_DIR/baselines/.pending.XXXXXX") || return 1
  if ! printf '%s\n' "$data" > "$temp" || ! chmod 600 "$temp" || ! mv -f "$temp" "$path"; then
    rm -f "$temp"; return 1
  fi
}

reconcile_report() {
  local key="$1" state="$2" desired="$3" observed="$4" reason="$5" changed="${6:-false}" row
  row=$(jq -cn --arg module "${VM_INIT_CURRENT_MODULE:-${key%%.*}}" --arg resource "$key" \
    --arg label "${VM_INIT_RESOURCE_LABEL:-$key}" \
    --arg state "$state" --arg expected "$desired" --arg observed "$observed" \
    --arg reason "$reason" --argjson changed "$changed" \
    '{module:$module,resource:$resource,label:$label,state:$state,expected:$expected,observed:$observed,reason:$reason,changed:$changed}') || return 1
  if [[ -n "${VM_INIT_RECONCILE_REPORT:-}" ]]; then printf '%s\n' "$row" >> "$VM_INIT_RECONCILE_REPORT"; fi
}

# Returns through RECONCILE_ACTION: unchanged, apply, drift, unknown.
# Desired and observed are canonical strings: rendered content, normalized
# values, or module-specific JSON. The baseline stores both to allow semantic
# adoption without claiming ownership of existing administrator configuration.
reconcile_decide() {
  local key="$1" desired="$2" observed="$3" legacy="${4:-0}" saved previous journal path
  RECONCILE_ACTION=unknown
  if ! saved=$(reconcile_load "$key"); then
    reconcile_report "$key" unknown "$desired" "$observed" 'Baseline is unreadable or invalid'
    log_fail "$key: cannot read a valid configuration baseline"; return 1
  fi
  if [[ "$desired" == "$observed" ]]; then
    RECONCILE_ACTION=unchanged
  elif [[ "${VM_INIT_RESTORE_CONFIG:-0}" == 1 ]] || should_force; then
    RECONCILE_ACTION=apply
  elif [[ "$saved" != null ]]; then
    previous=$(jq -r '.observed' <<< "$saved") || return 1
    if [[ "$observed" == "$previous" ]]; then RECONCILE_ACTION=apply
    else RECONCILE_ACTION=drift; fi
  elif [[ "$legacy" == 1 ]]; then
    RECONCILE_ACTION=drift
  else
    RECONCILE_ACTION=apply
  fi
  # A failed atomic resource update may have reached its intended value before
  # the baseline was committed. Never authorize a third, externally edited value.
  path=$(reconcile_path "$key") || return 1
  if [[ "$RECONCILE_ACTION" == drift && -f "$path.pending" ]]; then
    journal=$(jq -er --arg observed "$observed" --arg desired "$desired" \
      'select(.schema_version == 1 and .desired == $desired and (.before == $observed or .after == $observed)) | .desired' "$path.pending" 2>/dev/null || true)
    if [[ "$journal" == "$desired" ]]; then RECONCILE_ACTION=apply; fi
  fi
  case "$RECONCILE_ACTION" in
    unchanged) reconcile_report "$key" in_sync "$desired" "$observed" 'already matches' ;;
    apply) reconcile_report "$key" pending "$desired" "$observed" 'configuration change required' ;;
    drift)
      reconcile_report "$key" drifted "$desired" "$observed" 'local change or unverified previous configuration'
      log_warn "${VM_INIT_RESOURCE_LABEL:-$key}: configuration drift; current settings preserved"
      if [[ -z "${VM_INIT_RESOURCE_LABEL:-}" || "${VM_INIT_VERBOSE:-0}" == 1 ]]; then
        log_info "Expected: $desired"
        log_info "Observed: $observed"
      fi
      local restore_args=(sudo "${VM_INIT_EXECUTABLE:-vm-init}" apply)
      if [[ -n "${CONFIG:-}" ]]; then restore_args+=(--config "$CONFIG"); fi
      restore_args+=(--only "${VM_INIT_CURRENT_MODULE:-${key%%.*}}" --restore-config --no-upgrade)
      if [[ -n "${VM_INIT_TARGET_USERS:-}" ]]; then restore_args+=(--user "${VM_INIT_TARGET_USERS// /,}"); fi
      log_info "Restore with: $(shell_command "${restore_args[@]}")"
      ;;
  esac
}

reconcile_begin() {
  local key="$1" desired="$2" observed="$3" path data
  reconcile_readonly && return 0
  path=$(reconcile_path "$key") || return 1
  data=$(jq -cn --arg desired "$desired" --arg before "$observed" \
    '{schema_version:1,desired:$desired,before:$before,after:$desired}') || return 1
  reconcile_save "$path.pending" "$data"
}

reconcile_accept() {
  local key="$1" desired="$2" observed="$3" changed="${4:-false}" path data
  reconcile_report "$key" in_sync "$desired" "$observed" 'verified' "$changed" || return 1
  reconcile_readonly && return 0
  path=$(reconcile_path "$key") || return 1
  data=$(jq -cn --arg desired "$desired" --arg observed "$observed" --arg run "${VM_INIT_RUN_ID:-unknown}" \
    '{schema_version:1,desired:$desired,observed:$observed,run_id:$run}') || return 1
  reconcile_save "$path" "$data" || return 1
  rm -f "$path.pending"
}

reconcile_checkpoint() {
  local key="$1" observed="$2" path data
  path=$(reconcile_path "$key") || return 1
  data=$(jq --arg observed "$observed" '.after=$observed' "$path.pending") || return 1
  reconcile_save "$path.pending" "$data"
}

reconcile_legacy() {
  [[ -n "$(state_get "module.$1.status" 2>/dev/null || true)" ]]
}

reconcile_account_legacy() {
  local module="$1" user="$2" previous="${VM_INIT_PREVIOUS_CONFIG:-}"
  reconcile_legacy "$module" || return 1
  if [[ -z "$previous" ]]; then previous=$(state_get last.config 2>/dev/null || true); fi
  [[ -f "$previous" ]] || return 1
  yq -r '.users // [] | .[]' "$previous" | grep -qxF "$user"
}

inspect_service() {
  local module="$1" service="$2" legacy=0 actual
  actual=$(systemctl is-enabled "$service" 2>/dev/null) || { [[ -n "$actual" ]] || actual=absent; }
  if reconcile_legacy "$module"; then legacy=1; fi
  reconcile_decide "$module.service.$service" enabled "$actual" "$legacy" || return 1
  if ! systemctl is-active --quiet "$service"; then
    reconcile_report "$module.service.$service.runtime" pending active stopped 'service needs starting'
  fi
}

reconcile_file_value() {
  if [[ -L "$1" ]]; then printf 'symlink:%s\n' "$(readlink "$1")"
  elif [[ -f "$1" ]]; then _sha256_of "$1"
  elif [[ -e "$1" ]]; then printf 'not-a-file\n'
  else printf 'absent\n'; fi
}

# System-owned files only. Account files use write_shell_file after dropping
# privileges; they must never be handed to this root writer.
reconcile_file() {
  local key="$1" source="$2" destination="$3" mode="${4:-0644}" legacy="${5:-0}"
  local desired observed temp backup
  desired=$(reconcile_file_value "$source") || return 1
  observed=$(reconcile_file_value "$destination") || return 1
  reconcile_decide "$key" "$desired" "$observed" "$legacy" || return 1
  case "$RECONCILE_ACTION" in
    drift) return 2 ;;
    unchanged) reconcile_accept "$key" "$desired" "$observed"; return ;;
  esac
  reconcile_readonly && return 0
  reconcile_begin "$key" "$desired" "$observed" || return 1
  mkdir -p "$(dirname "$destination")" || return 1
  [[ "$(reconcile_file_value "$destination")" == "$observed" ]] || { log_fail "$destination changed during inspection"; return 1; }
  if [[ -e "$destination" || -L "$destination" ]]; then
    backup="$VM_INIT_STATE_DIR/baselines/${key}.${VM_INIT_RUN_ID:-backup}.bak"
    cp -a "$destination" "$backup" || return 1
  fi
  temp=$(mktemp "$(dirname "$destination")/.vm-init.XXXXXX") || return 1
  if ! cat "$source" > "$temp" || ! chmod "$mode" "$temp" || ! mv -f "$temp" "$destination"; then rm -f "$temp"; return 1; fi
  [[ "$(reconcile_file_value "$destination")" == "$desired" ]] || return 1
  reconcile_accept "$key" "$desired" "$desired" true
}

reconcile_service() {
  local module="$1" service="$2" legacy="${3:-0}" actual key="$1.service.$2"
  actual=$(systemctl is-enabled "$service" 2>/dev/null) || { [[ -n "$actual" ]] || return 1; }
  reconcile_decide "$key" enabled "$actual" "$legacy" || return 1
  [[ "$RECONCILE_ACTION" != drift ]] || return 2
  if [[ "$RECONCILE_ACTION" == apply ]]; then
    if ! reconcile_readonly; then
      reconcile_begin "$key" enabled "$actual" || return 1
      if [[ "$actual" == masked ]]; then
        run_quiet systemctl unmask "$service" || return 1
        local unmasked
        unmasked=$(systemctl is-enabled "$service" 2>/dev/null) || { [[ -n "$unmasked" ]] || return 1; }
        reconcile_checkpoint "$key" "$unmasked" || return 1
      fi
      run_quiet systemctl enable "$service" || return 1
      systemctl is-enabled --quiet "$service" || return 1
      reconcile_accept "$key" enabled enabled true || return 1
    fi
  else
    reconcile_accept "$key" enabled enabled || return 1
  fi
  if ! systemctl is-active --quiet "$service"; then
    if reconcile_readonly; then
      reconcile_report "$key.runtime" pending active stopped 'service needs starting'
      [[ "${VM_INIT_VERIFY:-0}" != 1 ]] || return 1
    else
      run_quiet systemctl start "$service" || return 1
      systemctl is-active --quiet "$service" || return 1
      reconcile_report "$key.runtime" in_sync active active 'service started' true
    fi
  fi
}

reconcile_summary() {
  local module="$1"
  if [[ ! -s "${VM_INIT_RECONCILE_REPORT:-}" ]]; then
    printf '{"configuration_state":"not_checked","changed":false,"differences":[]}\n'; return
  fi
  jq -sc --arg module "$module" '
    map(select(.module == $module)) as $all | $all | group_by(.resource) | map(.[-1]) as $rows |
    {configuration_state:(if any($rows[]; .state == "unknown") then "unknown"
      elif any($rows[]; .state == "drifted") then "drifted"
      elif any($rows[]; .state == "pending") then "pending"
      elif ($rows|length)>0 then "in_sync" else "not_checked" end),
     changed:any($all[]; .changed), differences:[$rows[] | select(.state != "in_sync") |
       {resource:(.label // .resource),expected,observed,reason}]}' "$VM_INIT_RECONCILE_REPORT"
}

inspect_configuration() {
  local module="$1" function="inspect_$1" required='' command
  local VM_INIT_CURRENT_MODULE="$module"
  declare -F "$function" >/dev/null || return 0
  case "$module" in
    dns) required='systemctl resolvectl ip' ;;
    fail2ban|docker) required=systemctl ;;
    shell) required=getent ;;
    github_tools|yazi) required=dpkg ;;
  esac
  for command in $required; do
    if ! command -v "$command" >/dev/null 2>&1; then
      reconcile_report "$module.inspection" unknown 'inspect current Ubuntu settings' unavailable "$command is unavailable"
      log_info "$module: current settings cannot be inspected ($command unavailable)"
      return 1
    fi
  done
  if ! "$function"; then
    reconcile_report "$module.inspection" unknown 'read current configuration' unavailable 'inspection failed'
    log_warn "$module: configuration inspection failed"
    return 1
  fi
}

reconcile_key_valid() (
  [[ -s "$1" ]] || return 1
  local key_home
  key_home=$(mktemp -d) || return 1
  trap 'rm -rf "$key_home"' EXIT
  gpg --homedir "$key_home" --batch --no-options --show-keys "$1" >/dev/null 2>&1
)

# Apt sources and keys form one resource. Existing keys are accepted only when
# parseable, then their fingerprint is retained to detect subsequent replacement.
reconcile_repository() (
  local module="$1" list="$2" keyring="$3" url="$4" source_line="$5" mode="${6:-apply}"
  local identity="$module.repository" desired observed actual_key wanted_key saved legacy=0 source_actual='' stage path data
  if ! command -v gpg >/dev/null 2>&1; then
    reconcile_report "$identity" unknown "$source_line" unknown 'gpg required to inspect repository keyring'
    log_warn "$module: gpg is required to inspect the repository keyring"
    [[ "$mode" == inspect ]] && return 0
    return 1
  fi
  if [[ -f "$list" ]]; then source_actual=$(awk '{$1=$1; if(NF && $1 !~ /^#/) print}' "$list") || return 1; fi
  actual_key=$(reconcile_file_value "$keyring") || return 1
  if [[ "$actual_key" != absent ]] && ! reconcile_key_valid "$keyring"; then actual_key=invalid; fi
  saved=$(reconcile_load "$identity") || return 1
  wanted_key="$actual_key"
  if [[ "$saved" != null ]]; then wanted_key=$(jq -r '.desired | fromjson | .key' <<< "$saved")
  elif [[ "$actual_key" == absent || "$actual_key" == invalid ]]; then wanted_key='valid upstream key'; fi
  desired=$(jq -cnS --arg source "$source_line" --arg key "$wanted_key" '{source:$source,key:$key}') || return 1
  observed=$(jq -cnS --arg source "$source_actual" --arg key "$actual_key" '{source:$source,key:$key}') || return 1
  if reconcile_legacy "$module"; then legacy=1; fi
  reconcile_decide "$identity" "$desired" "$observed" "$legacy" || return 1
  if [[ "$RECONCILE_ACTION" == drift ]]; then return 2; fi
  [[ "$mode" != inspect ]] && ! reconcile_readonly || return 0
  if [[ "$RECONCILE_ACTION" == unchanged ]]; then
    if [[ -f "$(reconcile_path "$identity").pending" ]]; then run_quiet apt_get update -q || return 1; fi
    reconcile_accept "$identity" "$desired" "$observed"; return
  fi
  reconcile_begin "$identity" "$desired" "$observed" || return 1
  stage=$(mktemp -d) || return 1
  trap 'rm -rf "$stage"' EXIT
  if [[ "$actual_key" != "$wanted_key" ]]; then
    download_file "$url" "$stage/download" || return 1
    reconcile_key_valid "$stage/download" || { log_fail "$module: invalid repository signing key"; return 1; }
    if head -n 1 "$stage/download" | grep -q '^-----BEGIN PGP'; then
      mkdir "$stage/gnupg"; chmod 700 "$stage/gnupg"
      gpg --homedir "$stage/gnupg" --batch --dearmor --output "$stage/key" "$stage/download" || return 1
    else cp "$stage/download" "$stage/key" || return 1; fi
    wanted_key=$(reconcile_file_value "$stage/key") || return 1
    desired=$(jq -cnS --arg source "$source_line" --arg key "$wanted_key" '{source:$source,key:$key}') || return 1
    reconcile_begin "$identity" "$desired" "$observed" || return 1
  fi
  for path in "$keyring" "$list"; do
    if [[ -e "$path" || -L "$path" ]]; then
      cp -a "$path" "$VM_INIT_STATE_DIR/baselines/${identity}.$(basename "$path").${VM_INIT_RUN_ID:-backup}.bak" || return 1
    fi
  done
  if [[ -f "$list" ]]; then
    [[ "$(awk '{$1=$1; if(NF && $1 !~ /^#/) print}' "$list")" == "$source_actual" ]] || { log_fail "$list changed during inspection"; return 1; }
  elif [[ -n "$source_actual" ]]; then log_fail "$list disappeared during inspection"; return 1; fi
  local key_now
  key_now=$(reconcile_file_value "$keyring") || return 1
  if [[ "$actual_key" != invalid && "$key_now" != "$actual_key" ]]; then log_fail "$keyring changed during inspection"; return 1; fi
  mkdir -p "$(dirname "$keyring")" "$(dirname "$list")" || return 1
  if [[ -f "$stage/key" ]]; then
    path=$(mktemp "$(dirname "$keyring")/.vm-init.XXXXXX") || return 1
    cat "$stage/key" > "$path"; chmod 0644 "$path"; mv -f "$path" "$keyring" || return 1
    data=$(jq -cnS --arg source "$source_actual" --arg key "$(reconcile_file_value "$keyring")" '{source:$source,key:$key}') || return 1
    reconcile_checkpoint "$identity" "$data" || return 1
  fi
  if [[ "$source_line" != "$source_actual" ]]; then
    path=$(mktemp "$(dirname "$list")/.vm-init.XXXXXX") || return 1
    printf '%s\n' "$source_line" > "$path"; chmod 0644 "$path"; mv -f "$path" "$list" || return 1
  fi
  reconcile_key_valid "$keyring" || return 1
  data=$(jq -cnS --arg source "$(awk '{$1=$1; if(NF && $1 !~ /^#/) print}' "$list")" --arg key "$(reconcile_file_value "$keyring")" '{source:$source,key:$key}') || return 1
  [[ "$data" == "$desired" ]] || return 1
  reconcile_checkpoint "$identity" "$data" || return 1
  run_quiet apt_get update -q || return 1
  reconcile_accept "$identity" "$desired" "$data" true
)
