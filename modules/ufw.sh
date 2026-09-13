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
  detect_ssh_connection
  yq -r '.ufw.allow // [] | .[]' "$CONFIG"
  local port="${SSH_CONNECTION:-}"
  port="${port##* }"
  if [[ -n "${SSH_CONNECTION:-}" && "$port" =~ ^[0-9]+$ ]]; then
    printf '%s/tcp\n' "$port"
  fi
}

ufw_rule_present() {
  local rule="$1" status="$2" family="${3:-4}"
  awk -v wanted="$rule" -v family="$family" '
    {
      sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "")
      n=split($0, col, /[ \t][ \t]+/)
      if(n < 3) next
      v6=(col[1] ~ / \(v6\)$/)
      sub(/ \(v6\)$/, "", col[1])
      sub(/[ \t]+#.*/, "", col[3]); sub(/ \(v6\)$/, "", col[3])
      if(col[1] == wanted && col[2] ~ /^(DENY|REJECT)/ && col[2] !~ /OUT/) blocked=1
      if(col[1] == wanted && (col[2] == "ALLOW" || col[2] == "ALLOW IN") && col[3] == "Anywhere" && v6 == (family == 6)) found=1
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
  local desired="$1" status="$2"
  awk -v desired="$desired" '
    BEGIN { n=split(desired, rules, "\n"); for(i=1;i<=n;i++) keep[rules[i]]=1 }
    /^[[] *[0-9]+[]]/ && /# vm-init$/ {
      number=$0; sub(/^[[] */, "", number); sub(/[]].*/, "", number)
      row=$0; sub(/^[[] *[0-9]+[]] */, "", row)
      split(row, col, /[ \t][ \t]+/); sub(/ \(v6\)$/, "", col[1])
      if(!keep[col[1]]) print number
    }
  ' <<< "$status" | sort -rn
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
  trap 'rc=$?; if [[ "$committed" != 1 ]]; then systemctl stop vm-init-firewall-rollback.timer >/dev/null 2>&1 || true; rm -f "$VM_INIT_STATE_DIR/firewall-pending"; if ! ufw_rollback "$snapshot"; then restored=0; log_fail "Firewall restoration failed; backup: $snapshot"; fi; fi; if [[ "$restored" == 1 && ! -f "$VM_INIT_STATE_DIR/firewall-pending" ]]; then rm -rf "$snapshot"; fi; exit "$rc"' EXIT
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    log_info "Preserving the current SSH port: ${SSH_CONNECTION##* }/tcp"
    ufw_schedule_rollback "$snapshot"
  fi
  # Keep IPv6 handling consistent before creating new rules.
  if [[ "$ipv6" == true ]]; then ipv6=yes; else ipv6=no; fi
  sed -i "s/^IPV6=.*/IPV6=${ipv6}/" "$root/etc/default/ufw"
  # Add rules before tightening policies, and never take ownership of a rule
  # that another administrator already created.
  status=$(LC_ALL=C ufw status)
  added=$(LC_ALL=C ufw show added)
  while IFS= read -r rule; do
    [[ -n "$rule" ]] || continue
    if ! ufw_rule_exists "$rule" "$added"; then
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
  verify_ufw
  touch "$snapshot/ready"
  committed=1
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    local confirm_command
    confirm_command=$(shell_command sudo "${VM_INIT_EXECUTABLE:-vm-init}" confirm-firewall)
    log_info "Open a new SSH session now and run: $confirm_command"
    log_info "Automatic rollback is scheduled after ${VM_INIT_FIREWALL_CONFIRM_SECONDS:-120}s. Other setup tasks can continue."
    vm_init_note "Confirm firewall changes from a new SSH session: $confirm_command (automatic rollback after ${VM_INIT_FIREWALL_CONFIRM_SECONDS:-120}s)."
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
  if [[ -f "$VM_INIT_STATE_DIR/firewall-pending" ]]; then
    log_warn 'Firewall confirmation is pending; reconnect and run confirm-firewall before automatic rollback'
  fi
  return "$rc"
}
