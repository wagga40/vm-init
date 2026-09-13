# Operations

## Installation and updates

The default layout is `/opt/vm-init/{app,bin,config,state,logs}`. `/usr/local/bin/vm-init`
links to its command entry point. Updates replace `app/`, preserving settings,
logs, retry history, and recovery snapshots. Configuration and saved run data
are private to root; use sudo to inspect the saved configuration.

The installer accepts `--prefix`, `--version`, and `--no-symlink`.
`VM_INIT_PREFIX`, `VM_INIT_BIN_DIR`, and `VM_INIT_NO_SYMLINK` also control bundle
installation. A managed installation remembers its prefix and command settings.
`VM_INIT_STATE_DIR` and `VM_INIT_STATE_FILE` remain available for isolated state.

A downloaded bundle installs itself on its first normal run. If a managed
installation already exists, it delegates to that command. Explicit `update`
verifies the release checksum and Bash syntax before replacement. Managed
tarball installs use the installer; checkout updates require a clean working
tree and fast-forwardable tracking branch.

Legacy `/etc/vm-init`, `/var/lib/vm-init`, and vm-init log files migrate into the
new layout during a mutating run. Compatibility links preserve old retry and
recovery paths. Conflicting old/new data stops migration without overwriting
either. Pending firewall confirmation must finish before state migration.

## Automation and diagnostics

```bash
sudo vm-init --yes --user root,alice --features shell,docker
sudo vm-init --config /opt/vm-init/config/team.yml --user alice,bob --fail-fast
sudo vm-init status --json --config /opt/vm-init/config/team.yml > status.json
sudo vm-init repair failed
```

First-run configuration needs a terminal or `--yes`. An existing explicit
configuration applies without prompting. Configuration is saved before modules
run; retries use the exact saved configuration, accounts, and unfinished modules.
Cancelling the wizard applies no modules and saves no configuration. Application
installation and prerequisite preparation may already have completed.

Apply exits nonzero for failures. Status also exits nonzero when requested
settings are unmet. Summaries distinguish ready modules, warnings, required
actions, failures, and unfinished work. Session reminders are informational.

`status --json` emits schema version 1 on stdout and diagnostics on stderr.
It includes run/configuration identifiers, module outcomes, configuration states,
differences, and classified messages. `configuration_state` is `in_sync`,
`pending`, `drifted`, `unknown`, or `not_checked`.

Mutations share one lock. Logs default to `/opt/vm-init/logs/vm-init-<run-id>.log`;
use `--log-file` or `--no-log`. Plans create no logs; status logs only on request.
Preview never installs prerequisites: if needed, normal execution prepares them,
or the optional `prepare` command can prepare tools without applying modules.
Both mikefarah yq v4 and compatible Python yq with jq are supported.

| Environment setting | Default |
| --- | --- |
| `VM_INIT_MIN_DISK_MB` | 2048; 0 disables the disk preflight |
| `VM_INIT_APT_LOCK_TIMEOUT` | 1800 seconds |
| `VM_INIT_CMD_TIMEOUT` | 900 seconds; 0 disables it |
| `VM_INIT_PROGRESS_INTERVAL` | 15 seconds |
| `VM_INIT_UPDATE_CHECK` | 1; 0 disables release notices |
| `NO_COLOR` | Set to disable colors |

## Firewall and DNS recovery

Remote firewall changes preserve the current SSH port and schedule rollback after
120 seconds. Confirm from a **new SSH session** while setup continues:

```bash
sudo vm-init confirm-firewall
```

Change the window with `VM_INIT_FIREWALL_CONFIRM_SECONDS`. Only vm-init-tagged
rules are removed when deleted from YAML; unrelated rules are preserved.
If SSH detection is unavailable, use `sudo --preserve-env=SSH_CONNECTION`.

DNS activation saves files, resolver links, service state, and per-link settings.
Failed activation rolls back automatically. Offline recovery is also embedded
in the single-file distribution and does not need configuration tools:

```bash
sudo vm-init repair dns
sudo vm-init repair dns --with-fallback
```

`--with-fallback` permits temporary public DNS if restoration is insufficient.
Use `--iface <name>` or `--fallback "1.1.1.1 9.9.9.9"` when needed.
The existing `vm-init-recover-dns` compatibility command remains usable.
After recovery, disable DNS management or explicitly restore the requested DNS
configuration with `--only dns --restore-config`.

Fail2ban supports `fail2ban.jails.sshd.enabled`. Inspect service failures with
`systemctl status fail2ban` and `journalctl -u fail2ban`.
