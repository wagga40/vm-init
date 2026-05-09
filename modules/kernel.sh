#!/usr/bin/env bash
# Kernel boot parameter management via /etc/default/grub.
# Reads: CONFIG (path to vm-init.yml)
#
# Currently supports a single toggle: kernel.mitigations_off. When enabled,
# `mitigations=off` is appended to GRUB_CMDLINE_LINUX_DEFAULT and update-grub
# is run. Disabling the toggle removes the parameter idempotently. Changes
# only take effect after reboot.

VM_INIT_GRUB_DEFAULTS="${VM_INIT_GRUB_DEFAULTS:-/etc/default/grub}"

install_kernel() {
  require_commands awk grep sed || return 1

  if [[ ! -f "$VM_INIT_GRUB_DEFAULTS" ]]; then
    log_warn "${VM_INIT_GRUB_DEFAULTS} not found — skipping kernel parameter changes"
    return 0
  fi

  local changed=0

  local mitigations_off
  mitigations_off=$(yq_get '.kernel.mitigations_off' false "$CONFIG")
  if [[ "$mitigations_off" == "true" ]]; then
    if _kernel_cmdline_has "mitigations=off"; then
      log_skip "mitigations=off already in GRUB_CMDLINE_LINUX_DEFAULT"
    else
      log_step "Adding mitigations=off to GRUB_CMDLINE_LINUX_DEFAULT"
      _kernel_backup_grub
      _kernel_cmdline_add "mitigations=off"
      changed=1
      log_ok "mitigations=off added"
    fi
  else
    if _kernel_cmdline_has "mitigations=off"; then
      log_step "Removing mitigations=off from GRUB_CMDLINE_LINUX_DEFAULT"
      _kernel_backup_grub
      _kernel_cmdline_remove "mitigations=off"
      changed=1
      log_ok "mitigations=off removed"
    fi
  fi

  if (( changed )); then
    if ! command -v update-grub >/dev/null 2>&1; then
      log_warn "update-grub not found — bootloader config not regenerated"
      return 0
    fi
    log_step "Running update-grub"
    run_quiet update-grub
    log_ok "update-grub complete (reboot to apply)"
  fi
}

# Keep one timestamped backup the first time we touch grub. Subsequent edits
# don't overwrite it, so the original is always recoverable.
_kernel_backup_grub() {
  local backup="${VM_INIT_GRUB_DEFAULTS}.vm-init.bak"
  if [[ ! -f "$backup" ]]; then
    cp -p "$VM_INIT_GRUB_DEFAULTS" "$backup"
    log_info "Backed up ${VM_INIT_GRUB_DEFAULTS} → ${backup}"
  fi
}

# Print the current GRUB_CMDLINE_LINUX_DEFAULT value (without surrounding quotes).
# Returns 1 if the variable is not present.
_kernel_cmdline_value() {
  awk '
    /^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=/ {
      sub(/^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=/, "")
      gsub(/^["\x27]|["\x27]$/, "")
      print
      found=1
      exit
    }
    END { if (!found) exit 1 }
  ' "$VM_INIT_GRUB_DEFAULTS"
}

_kernel_cmdline_has() {
  local needle="$1" current
  current=$(_kernel_cmdline_value 2>/dev/null) || return 1
  [[ " ${current} " == *" ${needle} "* ]]
}

_kernel_cmdline_add() {
  local param="$1" current new
  current=$(_kernel_cmdline_value 2>/dev/null || echo "")
  if [[ -n "$current" ]]; then
    new="${current} ${param}"
  else
    new="${param}"
  fi
  _kernel_cmdline_set "$new"
}

_kernel_cmdline_remove() {
  local param="$1" current new
  current=$(_kernel_cmdline_value 2>/dev/null) || return 0
  new=$(printf '%s\n' "$current" \
    | tr ' ' '\n' \
    | grep -vxF "$param" \
    | tr '\n' ' ' \
    | sed -E 's/[[:space:]]+$//; s/^[[:space:]]+//')
  _kernel_cmdline_set "$new"
}

# Replace (or append) GRUB_CMDLINE_LINUX_DEFAULT="<new_value>" in /etc/default/grub.
# Reject embedded double quotes — we don't currently need them and they would
# require shell-escaping the awk replacement.
_kernel_cmdline_set() {
  local new_value="$1" tmp
  if [[ "$new_value" == *\"* ]]; then
    log_fail "kernel cmdline value must not contain double quotes: ${new_value}"
    return 1
  fi
  tmp=$(mktemp) || return 1

  if grep -qE '^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=' "$VM_INIT_GRUB_DEFAULTS"; then
    awk -v val="$new_value" '
      BEGIN { replaced=0 }
      /^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=/ && !replaced {
        print "GRUB_CMDLINE_LINUX_DEFAULT=\"" val "\""
        replaced=1
        next
      }
      { print }
    ' "$VM_INIT_GRUB_DEFAULTS" > "$tmp"
  else
    cat "$VM_INIT_GRUB_DEFAULTS" > "$tmp"
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$new_value" >> "$tmp"
  fi

  mv "$tmp" "$VM_INIT_GRUB_DEFAULTS"
  chmod 644 "$VM_INIT_GRUB_DEFAULTS"
}
