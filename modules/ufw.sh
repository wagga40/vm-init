#!/usr/bin/env bash
# Only rules tagged "vm-init" are removed during reconciliation.

detect_ssh_connection() {
  [[ -z "${SSH_CONNECTION:-}" ]] || return 0
  # sudo commonly filters SSH_CONNECTION from its child's environment. Recover
  # only that variable from the invoking process; never print its environment.
  local pid="$PPID" entry depth
  for ((depth=0; depth<6; depth++)); do
    [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || break
    if [[ -r "/proc/$pid/environ" ]]; then
      while IFS= read -r -d '' entry; do
        if [[ "$entry" == SSH_CONNECTION=* ]]; then
          export SSH_CONNECTION="${entry#SSH_CONNECTION=}"
          return 0
        fi
      done < "/proc/$pid/environ"
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || break
  done
  return 0
}

ufw_effective_rules() {
  if [[ "${VM_INIT_UFW_BASELINE:-0}" == 1 ]]; then
    yq -r '.ufw.allow // [] | .[]' "$CONFIG"; return
  fi
  detect_ssh_connection
  yq -r '.ufw.allow // [] | .[]' "$CONFIG"
  local port="${SSH_CONNECTION:-}"
  port="${port##* }"
  if [[ -n "${SSH_CONNECTION:-}" && "$port" =~ ^[0-9]+$ ]]; then
    printf '%s/tcp\n' "$port"
  fi
}

ufw_desired_config() {
  local rules
  rules=$(ufw_effective_rules | sort -u | jq -Rn '[inputs | select(length>0)]') || return 1
  jq -cnS --arg incoming "$(yq_get '.ufw.defaults.incoming' deny "$CONFIG")" \
    --arg outgoing "$(yq_get '.ufw.defaults.outgoing' allow "$CONFIG")" \
    --argjson ipv6 "$(yq_get '.ufw.ipv6' true "$CONFIG")" --argjson rules "$rules" \
    '{ufw:{enabled:true,defaults:{incoming:$incoming,outgoing:$outgoing},ipv6:$ipv6,allow:$rules}}'
}

ufw_config_matches() {
  local candidate rc=0
  candidate=$(mktemp) || return 1
  printf '%s\n' "$1" > "$candidate"
  CONFIG="$candidate" VM_INIT_NOTES_FILE='' VM_INIT_UFW_BASELINE=1 verify_ufw applying >/dev/null 2>&1 || rc=$?
  rm -f "$candidate"
  return "$rc"
}

inspect_ufw() {
  local saved old legacy=0
  UFW_DESIRED=$(ufw_desired_config) || return 1
  saved=$(reconcile_load ufw.configuration) || { log_fail 'Cannot read firewall baseline'; return 1; }
  if ! is_installed ufw; then UFW_OBSERVED=absent
  elif ufw_config_matches "$UFW_DESIRED"; then UFW_OBSERVED="$UFW_DESIRED"
  elif [[ "$saved" != null ]] && old=$(jq -r '.desired' <<< "$saved") && ufw_config_matches "$old"; then
    UFW_OBSERVED=$(jq -r '.observed' <<< "$saved")
  else
    UFW_OBSERVED=$(LC_ALL=C ufw status verbose) || return 1
    UFW_OBSERVED+=$'\n'"IPV6=$(sed -n 's/^IPV6=//p' "${VM_INIT_UFW_ROOT:-}/etc/default/ufw")"
  fi
  if reconcile_legacy ufw || [[ -n "$(LC_ALL=C ufw show added 2>/dev/null | grep 'vm-init' || true)" ]]; then legacy=1; fi
  reconcile_decide ufw.configuration "$UFW_DESIRED" "$UFW_OBSERVED" "$legacy"
}

ufw_canonical_rule() {
  local rule="${1%% (*}" ports
  if [[ "$rule" =~ ^[0-9,:]+(/(tcp|udp))?$ ]]; then printf '%s\n' "$rule"; return 0; fi
  ports=$(LC_ALL=C ufw app info "$rule" 2>/dev/null | awk '
    /^Ports?:/ { collecting=1; next }
    collecting { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); if(length) print }
  ') || ports=''
  if [[ -n "$ports" ]]; then printf '%s\n' "$ports" | tr '|' '\n'
  else printf '%s\n' "$rule"; fi
}

ufw_rule_present() {
  local rule="$1" status="$2" family="${3:-4}" canonical
  while read -r canonical; do
    [[ -n "$canonical" ]] || continue
    ufw_rule_present_literal "$canonical" "$status" "$family" || return 1
  done < <(ufw_canonical_rule "$rule")
  return 0
}

ufw_rule_present_literal() {
  local rule="$1" status="$2" family="${3:-4}"
  awk -v wanted="$rule" -v family="$family" '
    {
      sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "")
      n=split($0, col, /[ \t][ \t]+/)
      if(n < 3) next
      v6=(col[1] ~ / \(v6\)/)
      sub(/ \(v6\)/, "", col[1])
      # Verbose status expands profiles, e.g. "22/tcp (OpenSSH)".
      profile=col[1]
      if (sub(/^.* \(/, "", profile)) sub(/\)$/, "", profile)
      else profile=""
      sub(/ \(.*\)$/, "", col[1])
      sub(/[ \t]+#.*/, "", col[3]); sub(/ \(v6\)$/, "", col[3])
      matches=(col[1] == wanted || profile == wanted)
      if(matches && col[3] == "Anywhere" && v6 == (family == 6)) {
        if(col[2] ~ /^(DENY|REJECT)/ && col[2] !~ /OUT/) blocked=1
        if(col[2] == "ALLOW" || col[2] == "ALLOW IN") found=1
      }
    }
    END { exit (!found || blocked) }
  ' <<< "$status"
}

ufw_rule_exists() {
  local rule="$1" added="$2"
  python3 -c '
import shlex, sys
wanted = sys.argv[1]
for line in sys.stdin:
    try:
        tokens = shlex.split(line)
    except ValueError:
        continue
    if tokens[:2] == ["ufw", "allow"]:
        tokens = tokens[2:]
        if tokens[:1] == ["in"]:
            tokens = tokens[1:]
        if tokens[:1] == [wanted]:
            sys.exit(0)
sys.exit(1)
' "$rule" <<< "$added"
}

# Numbered output preserves rule order; deletion must run in descending order.
ufw_stale_rule_numbers() {
  local desired="$1" status="$2" canonical_desired='' rule canonical number stale
  while IFS= read -r rule; do
    [[ -n "$rule" ]] || continue
    canonical_desired+="$(ufw_canonical_rule "$rule")"$'\n'
  done <<< "$desired"
  while IFS=$'\t' read -r number rule; do
    stale=0
    while read -r canonical; do
      if ! grep -qxF "$canonical" <<< "$canonical_desired"; then stale=1; fi
    done < <(ufw_canonical_rule "$rule")
    if [[ "$stale" == 1 ]]; then printf '%s\n' "$number"; fi
  done < <(awk '
    /^[[] *[0-9]+[]]/ && /# vm-init$/ {
      number=$0; sub(/^[[] */, "", number); sub(/[]].*/, "", number)
      row=$0; sub(/^[[] *[0-9]+[]] */, "", row)
      split(row, col, /[ \t][ \t]+/); sub(/ \(v6\)$/, "", col[1])
      print number "\t" col[1]
    }
  ' <<< "$status") | sort -rn
}

ufw_rollback() {
  local snapshot="$1"
  restore_paths "$snapshot" || return 1
  if [[ "$(cat "$snapshot/active")" == 1 ]]; then ufw --force enable && ufw reload
  else ufw --force disable; fi
}

ufw_lock() {
  mkdir -p "$VM_INIT_STATE_DIR" || return 1
  exec {VM_INIT_FIREWALL_LOCK_FD}>"$VM_INIT_STATE_DIR/firewall.lock"
  if ! flock -n "$VM_INIT_FIREWALL_LOCK_FD"; then
    log_fail 'Firewall changes or rollback are still running; retry in a moment'
    return 1
  fi
}

# For SSH sessions, a systemd timer survives disconnects and process death.
# The admin confirms from a NEW SSH session with "vm-init confirm-firewall".
ufw_schedule_rollback() {
  local snapshot="$1" script="$1/rollback.sh" root="${VM_INIT_UFW_ROOT:-}"
  [[ -z "$root" ]] || return 0
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    declare -f restore_paths ufw_rollback
    printf 'exec 9>%q\nflock 9\n' "$VM_INIT_STATE_DIR/firewall.lock"
    printf '[[ -f %q ]] || exit 0\n' "$VM_INIT_STATE_DIR/firewall-pending"
    # shellcheck disable=SC2016 # expanded by the rollback process
    printf '[[ "$(head -n 1 %q)" == %q ]] || exit 0\n' "$VM_INIT_STATE_DIR/firewall-pending" "$snapshot"
    printf 'touch %q\n' "$snapshot/rollback-started"
    printf 'ufw_rollback %q\n' "$snapshot"
    printf 'printf "%%s rolled_back\\n" %q > %q\n' "${VM_INIT_RUN_ID:-unknown}" "$VM_INIT_STATE_DIR/firewall-result"
    printf 'rm -f %q\n' "$VM_INIT_STATE_DIR/firewall-pending"
    printf 'rm -rf %q\n' "$snapshot"
  } > "$script"
  chmod 700 "$script"
  without_run_lock systemd-run --quiet --collect --unit=vm-init-firewall-rollback \
    --timer-property=AccuracySec=1s \
    --on-active="${VM_INIT_FIREWALL_CONFIRM_SECONDS:-120}s" /bin/bash "$script" || return 1
  printf '%s\n%s\n%s\n' "$snapshot" "${SSH_CONNECTION:-}" "${VM_INIT_RUN_ID:-unknown}" > "$VM_INIT_STATE_DIR/firewall-pending"
  printf '%s pending\n' "${VM_INIT_RUN_ID:-unknown}" > "$VM_INIT_STATE_DIR/firewall-result"
}

confirm_firewall() (
  # Confirmation must remain available while other setup modules hold run.lock.
  detect_ssh_connection
  ufw_lock || return 1
  local pending="$VM_INIT_STATE_DIR/firewall-pending" snapshot original run_id
  [[ -f "$pending" ]] || { log_fail 'No firewall change is waiting for confirmation'; return 1; }
  { read -r snapshot; read -r original; read -r run_id || true; } < "$pending"
  if [[ -n "$original" && ( -z "${SSH_CONNECTION:-}" || "$SSH_CONNECTION" == "$original" ) ]]; then
    log_fail 'Open a new SSH session, then run: sudo vm-init confirm-firewall'
    return 1
  fi
  [[ -f "$snapshot/ready" ]] || { log_fail 'Firewall changes have not passed verification yet'; return 1; }
  if [[ -f "$snapshot/rollback-started" ]]; then
    log_fail "Rollback started but did not complete. Inspect ufw status; backup retained at $snapshot"
    return 1
  fi
  systemctl stop vm-init-firewall-rollback.timer || return 1
  # The rollback shares firewall.lock and rechecks this file before acting.
  if [[ ! -f "$pending" ]]; then
    log_fail 'The rollback already started; check firewall status before applying again'
    return 1
  fi
  if [[ -f "$snapshot/baseline.json" ]]; then
    reconcile_save "$(reconcile_path ufw.configuration)" "$(cat "$snapshot/baseline.json")" || return 1
    rm -f "$(reconcile_path ufw.configuration).pending"
  fi
  rm -f "$pending"
  printf '%s confirmed\n' "${run_id:-unknown}" > "$VM_INIT_STATE_DIR/firewall-result"
  rm -rf "$snapshot"
  log_done 'Firewall changes kept.'
)

install_ufw() (
  set -e
  require_commands apt-get sed || return 1
  detect_ssh_connection
  ufw_lock || return 1
  if [[ -f "$VM_INIT_STATE_DIR/firewall-pending" ]]; then
    log_fail 'A firewall change is waiting for confirmation. Use a new SSH session to confirm it, or wait for rollback.'
    return 1
  fi
  if ! is_installed ufw; then
    run_quiet apt_get update -q
    run_quiet apt_get install -y -q ufw
  fi
  inspect_ufw || return 1
  if [[ "$RECONCILE_ACTION" == drift ]]; then return 0; fi
  if [[ "$RECONCILE_ACTION" == unchanged ]]; then
    reconcile_accept ufw.configuration "$UFW_DESIRED" "$UFW_OBSERVED" || return 1
    log_ok 'Firewall unchanged; requested policies and rules already match'
    return 0
  fi
  reconcile_begin ufw.configuration "$UFW_DESIRED" "$UFW_OBSERVED" || return 1
  local root="${VM_INIT_UFW_ROOT:-}" desired status added numbered rule number incoming outgoing ipv6
  snapshot="" committed=0 restored=1
  desired=$(ufw_effective_rules | sort -u)
  incoming=$(yq_get '.ufw.defaults.incoming' deny "$CONFIG")
  outgoing=$(yq_get '.ufw.defaults.outgoing' allow "$CONFIG")
  ipv6=$(yq_get '.ufw.ipv6' true "$CONFIG")
  mkdir -p "$VM_INIT_STATE_DIR"
  snapshot=$(mktemp -d "$VM_INIT_STATE_DIR/firewall.XXXXXX")
  snapshot_paths "$snapshot" "$root/etc/ufw" "$root/etc/default/ufw"
  if ufw status | grep -q '^Status: active'; then echo 1; else echo 0; fi > "$snapshot/active"
  trap '
    rc=$?
    if [[ "$committed" != 1 ]]; then
      systemctl stop vm-init-firewall-rollback.timer >/dev/null 2>&1 || true
      rm -f "$VM_INIT_STATE_DIR/firewall-pending"
      log_warn "Firewall setup failed; restoring the previous rules"
      if ufw_rollback "$snapshot"; then
        log_ok "Previous firewall rules restored; no confirmation is needed"
      else
        restored=0
        log_fail "Firewall restoration failed; backup: $snapshot"
      fi
    fi
    if [[ "$restored" == 1 && ! -f "$VM_INIT_STATE_DIR/firewall-pending" ]]; then rm -rf "$snapshot"; fi
    exit "$rc"
  ' EXIT
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    log_info "Preserving the current SSH port: ${SSH_CONNECTION##* }/tcp"
    ufw_schedule_rollback "$snapshot"
  fi
  # Keep IPv6 handling consistent before creating new rules.
  if [[ "$ipv6" == true ]]; then ipv6=yes; else ipv6=no; fi
  sed -i "s/^IPV6=.*/IPV6=${ipv6}/" "$root/etc/default/ufw"
  # Add rules before tightening policies, and never take ownership of a rule
  # that another administrator already created.
  status=$(LC_ALL=C ufw status verbose)
  added=$(LC_ALL=C ufw show added)
  local have_stale=0
  if [[ -n "$(ufw_stale_rule_numbers "$desired" "$(LC_ALL=C ufw status numbered)")" ]]; then have_stale=1; fi
  while IFS= read -r rule; do
    [[ -n "$rule" ]] || continue
    if [[ "$have_stale" == 0 ]] && ufw_rule_present "$rule" "$status" 4 && { [[ "$ipv6" == no ]] || ufw_rule_present "$rule" "$status" 6; }; then
      continue
    elif ! ufw_rule_exists "$rule" "$added"; then
      run_quiet ufw allow "$rule" comment vm-init
    elif [[ "$ipv6" == yes ]] && ! ufw_rule_present "$rule" "$status" 6; then
      run_quiet ufw allow "$rule"
    fi
  done <<< "$desired"
  numbered=$(LC_ALL=C ufw status numbered)
  while read -r number; do
    [[ -n "$number" ]] || continue
    run_quiet ufw --force delete "$number"
  done < <(ufw_stale_rule_numbers "$desired" "$numbered")
  run_quiet ufw default "$incoming" incoming
  run_quiet ufw default "$outgoing" outgoing
  run_quiet ufw --force enable
  run_quiet ufw reload
  verify_ufw applying
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    jq -cn --arg desired "$UFW_DESIRED" --arg run "${VM_INIT_RUN_ID:-unknown}" \
      '{schema_version:1,desired:$desired,observed:$desired,run_id:$run}' > "$snapshot/baseline.json"
    reconcile_report ufw.configuration pending "$UFW_DESIRED" "$UFW_DESIRED" 'awaiting SSH confirmation' true
  else
    reconcile_accept ufw.configuration "$UFW_DESIRED" "$UFW_DESIRED" true
  fi
  touch "$snapshot/ready"
  committed=1
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    local confirm_command
    confirm_command=$(shell_command sudo "${VM_INIT_EXECUTABLE:-vm-init}" confirm-firewall)
    log_info "Open a new SSH session now and run: $confirm_command"
    log_info "Automatic rollback is scheduled after ${VM_INIT_FIREWALL_CONFIRM_SECONDS:-120}s. Other setup tasks can continue."
    vm_init_note "Confirm firewall changes from a new SSH session: $confirm_command (automatic rollback ${VM_INIT_FIREWALL_CONFIRM_SECONDS:-120}s after firewall changes began)." action 'confirm firewall'
  fi
)

verify_ufw() {
  require_commands ufw || return 1
  local status rules rule incoming outgoing ipv6 actual rc=0
  status=$(LC_ALL=C ufw status verbose) || return 1
  if ! grep -q '^Status: active' <<< "$status"; then
    log_fail 'ufw is installed but not active'; return 1
  fi
  incoming=$(yq_get '.ufw.defaults.incoming' deny "$CONFIG")
  outgoing=$(yq_get '.ufw.defaults.outgoing' allow "$CONFIG")
  if [[ "$status" != *"Default: ${incoming} (incoming), ${outgoing} (outgoing)"* ]]; then
    log_fail 'Firewall default policies differ from config'; rc=1
  fi
  ipv6=$(yq_get '.ufw.ipv6' true "$CONFIG")
  actual=$(sed -n 's/^IPV6=//p' "${VM_INIT_UFW_ROOT:-}/etc/default/ufw") || return 1
  if [[ "$ipv6:$actual" != true:yes && "$ipv6:$actual" != false:no ]]; then
    log_fail 'Firewall IPv6 setting differs from config'; rc=1
  fi
  rules=$(ufw_effective_rules | sort -u)
  while IFS= read -r rule; do
    [[ -n "$rule" ]] || continue
    if ! ufw_rule_present "$rule" "$status" 4; then
      log_fail "IPv4 allow rule missing: $rule"; rc=1
    fi
    if [[ "$ipv6" == true ]] && ! ufw_rule_present "$rule" "$status" 6; then
      log_fail "IPv6 allow rule missing: $rule"; rc=1
    fi
  done <<< "$rules"
  if [[ -n "$(ufw_stale_rule_numbers "$rules" "$(LC_ALL=C ufw status numbered)")" ]]; then
    log_fail 'Obsolete vm-init firewall rules remain active'; rc=1
  fi
  if (( rc == 0 )); then log_ok 'Firewall active; requested policies and allow rules match'; fi
  if [[ "${1:-status}" != applying && -f "$VM_INIT_STATE_DIR/firewall-pending" ]]; then
    log_info 'Firewall confirmation is pending; reconnect and run confirm-firewall before automatic rollback'
    vm_init_note "From a new SSH session, run: $(shell_command sudo "${VM_INIT_EXECUTABLE:-vm-init}" confirm-firewall) before the scheduled automatic rollback." action 'confirm firewall'
  fi
  return "$rc"
}
