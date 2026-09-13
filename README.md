# vm-init

[![CI](https://github.com/wagga40/vm-init/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/wagga40/vm-init/actions/workflows/ci.yml)

Set up an Ubuntu development machine with a short guided flow, or use YAML for repeatable administration. The baseline installs useful packages and configures Fish for the selected account. Docker, Python tools, networking, security, and additional tools are opt-in.

## Get started

Run the installer on Ubuntu. It verifies the release tarball, installs under `/opt/vm-init`, creates the `vm-init` command, and prepares the configuration tools:

```bash
curl -fsSL https://raw.githubusercontent.com/wagga40/vm-init/main/scripts/install.sh | sudo bash
sudo vm-init setup
```

Setup asks for an account and features, shows the proposed changes, and asks before applying them. It saves the configuration to `/etc/vm-init/vm-init.yml`. An existing file is backed up with the run ID before replacement.

```text
Set up this machine

Account [alice]:
Features: shell, docker, python, tools
Choose a comma-separated list [shell]: shell,docker

Preview changes
  ...packages, selected accounts, and follow-up actions...

Save configuration to: /etc/vm-init/vm-init.yml
Apply these changes? [y/N]:
```

Use `sudo vm-init status` afterward to check the selected features. When setup asks you to start a new session, log out and back in to use the new shell or Docker group membership.

## Everyday commands

| Command | Purpose |
| --- | --- |
| `sudo vm-init setup` | Choose an account and features, preview, and apply |
| `vm-init plan` | Preview the selected configuration without system changes |
| `sudo vm-init apply` | Apply the configuration; a bare `sudo vm-init` does the same |
| `sudo vm-init status` | Verify selected features and report drift |
| `sudo vm-init repair failed` | Retry failed or interrupted work with its saved config and options |
| `sudo vm-init repair dns` | Restore DNS without needing a download or configuration parser |
| `sudo vm-init update` | Update vm-init according to its installation layout |

Existing options remain supported: `--dry-run`, `--verify`, `--update`, `--only`, `--skip`, `--config`/`-c`, `--force`/`-f`, `--no-upgrade`, `--fail-fast`, `--verbose`, `--list-modules`/`-l`, and `--write-default-config`/`-w`. Use `--restore-config` with apply or plan to restore managed settings to the selected YAML. Read-only modes cannot be combined with an update, recovery, or another write command.

```bash
vm-init plan --config ./team.yml
sudo vm-init apply --config ./team.yml --user alice
sudo vm-init status --config ./team.yml --only docker
sudo vm-init apply --config ./team.yml --skip github_releases --no-upgrade
vm-init --list-modules --config ./team.yml
```

Progress counts selected modules only. Disabled modules are collapsed into one summary line; use `--verbose` or `--list-modules` for details. Long quiet commands print a periodic “Still working” message.

The summary distinguishes **Ready** (completed), **Warnings** (completed with caveats), **Needs action** (an explicit step remains), **Failed**, and **Not run** (stopped by an earlier failure). Dry runs show **Planned**. Each module is counted once; failures take precedence over actions, and actions over warnings. Warning details remain visible even when a module also needs action.

Follow-ups are grouped into **Required actions**, **Warnings**, **Session changes**, and **Notes**, with the module named beside each message. Firewall confirmation, alias conflicts, and pending reboots need action. Starting a new shell session or activating Docker group membership is a session reminder; a DNS recovery tip is informational. Neither reminder makes a ready module warn. The final result reports success, warnings, or outstanding actions once, without a green “Setup complete” after warnings or required actions.

`status --json` uses the same distinction: `warned` has `observed_state: "warnings"`, while `needs_action` has `observed_state: "needs_action"`. Its `messages` array includes each message's `kind`, `module`, `summary`, and `message`. During apply, warnings and pending actions exit successfully; failures exit nonzero. Status also exits nonzero when requested configuration is unmet.

On Ubuntu, plans show installed and candidate APT versions from the local cache. Applying may refresh that cache and resolve additional dependencies, so these versions are an estimate. Shell plans also list the managed file for each account.

## Repeat runs and configuration drift

`apply` compares the selected configuration, current settings, and the last verified baseline. Configuration modules report whether settings changed or remained unchanged. A matching firewall needs no reload or new SSH confirmation; unchanged shell files and login shells need no new session reminder. An enabled service that has stopped is started and checked without rewriting its configuration.

| Current situation | Apply behavior |
| --- | --- |
| Requested settings already match | Keep them and record the verified baseline |
| New module or account | Initialize the requested settings |
| YAML changed and live settings still match the baseline | Apply the required changes |
| Live settings changed outside vm-init | Preserve the changes and warn about drift |
| Both YAML and live settings changed incompatibly | Preserve the affected configuration and report the conflict |
| Previously managed settings have no reliable baseline | Adopt matching settings; preserve unexplained mismatches |

To restore drift to your selected YAML, preview and apply the same scoped operation:

```bash
sudo vm-init plan --config /etc/vm-init/vm-init.yml --only ufw,shell --restore-config --no-upgrade
sudo vm-init apply --config /etc/vm-init/vm-init.yml --only ufw,shell --restore-config --no-upgrade
sudo vm-init status --config /etc/vm-init/vm-init.yml --only ufw,shell
```

Restoration respects module filters and selected accounts. It preserves unrelated firewall rules and user startup files. An external override that prevents the requested effective configuration still requires manual resolution. `--force` retains its broader tool reinstall behavior and also permits configuration restoration. It does not require rewriting settings that already match.

Software updates keep their existing policy. A normal apply can check and update packages or plugins even when configuration is unchanged; `--no-upgrade` skips updates to installed software while still installing missing dependencies. Configuration restoration does not itself force package reinstalls or downgrades. `update` continues to update vm-init itself.

Baselines and interrupted resource updates are saved privately under `/var/lib/vm-init/baselines/`. Successful resources keep their own baselines when another resource fails. `repair failed` preserves the restoration option and rechecks saved partial work before resuming. Firewall baselines become final only after remote confirmation; a rollback retains the previous baseline.

`plan` and `status` never advance baselines. Plans report `unknown` when permissions or local tools prevent inspection. `status --json` retains schema version 1 and existing statuses, with additive module fields: `configuration_state` (`in_sync`, `pending`, `drifted`, `unknown`, or `not_checked`), `changed`, and `differences` containing each resource's expected and observed state and reason. Configuration drift is a warning during apply; status exits nonzero while requested settings are unmet. Existing pending reboots and firewall confirmations remain visible even if no new configuration changes are needed.

## Accounts and configuration

Shell and Docker use the same account selection:

1. `--user alice,bob`, or the explicit `--all-users` option.
2. `users: [alice, bob]` in the configuration.
3. The invoking sudo user, or the only human account on a root-run machine.

A root run with no unambiguous human account asks for an explicit selection. Use `--user root` to configure root deliberately. `--all-users` includes root and all human accounts; it is never the default. Docker group membership is applied to the selected non-root accounts.

Configuration precedence is:

1. `--config <path>`.
2. `/etc/vm-init/vm-init.yml`.
3. `./vm-init.yml` in the current directory.
4. The configuration beside the installed script.
5. The embedded default in a single-file bundle.

The run prints which source was chosen. `--write-default-config` writes `./vm-init.yml` and refuses to overwrite an existing file. An omitted module is disabled. A disabled module is **not managed by that run**: disabling it does not uninstall packages or stop an already running service.

```yaml
users: [alice]

apt:
  enabled: true
  packages:
    shell: [fish, bat, zoxide]
    extra: [jq, git, curl]

shell:
  enabled: true
  default_shell: fish
  fisher: false
  tide: false
  zoxide: true
  direnv: false
  aliases:
    ll: ls -ahlF --group-directories-first
    cat: bat

docker:
  enabled: true
```

Configuration is checked before applying or listing modules. Invalid booleans, module shapes, package names, and unsupported settings produce a field-specific error. Both mikefarah yq v4 and compatible Python yq with jq are supported; a compatibility probe rejects unrelated programs named `yq`.

## Features

| Module | Default | What it manages |
| --- | --- | --- |
| `apt` | on | Editors, development utilities, terminal tools, and package dependencies |
| `shell` | on | Fish or Bash for selected accounts, aliases, optional zoxide/direnv and Fisher/Tide |
| `docker` | off | Docker Engine, Buildx, Compose, and selected users' group membership |
| `python` | off | pipx tools, including uv and pre-commit |
| `github_tools` | off | GitHub CLI and optional act |
| `github_releases` | off | Configured release binaries and additional terminal tools |
| `yazi` | off | Yazi and its upstream APT repository |
| `ufw` | off | Firewall policies and vm-init-owned allow rules |
| `fail2ban` | off | Fail2ban and an optional SSH jail |
| `dns` | off | dnsproxy with encrypted DNS and systemd-resolved routing |
| `kernel` | off | The `mitigations_off` boot-parameter setting; requires reboot |

Shell preparation includes the packages required by its selected integrations and known aliases. Ubuntu's `batcat` command is used for bat aliases when `bat` is not on PATH. Managed Fish settings live in `~/.config/fish/conf.d/90-vm-init.fish`; managed Bash settings live in `~/.config/vm-init/bash.sh`, loaded by `.bashrc`. A YAML change replaces the managed file when needed, so removed aliases do not accumulate. Local edits are preserved as drift until restoration is requested; replaced shell files retain a `.vm-init.bak` backup. Other application configuration files are preserved.

GitHub release tools can be added declaratively:

```yaml
github_releases:
  enabled: true
  generic:
    - repo: owner/repo
      asset_pattern: "tool_{version}_Linux_{arch}.tar.gz"
      binary: tool
      arch_map: {amd64: x86_64, arm64: arm64}
```

Available checksums must match before installation. Upstreams without sidecars produce an explicit warning. `--no-upgrade` skips API requests for release binaries already installed. Unmanaged binaries with unknown versions are not labelled as the latest release; a normal apply installs a known release once to establish their state.

## Firewall and DNS recovery

UFW changes preserve the current SSH port when `SSH_CONNECTION` is available. A matching firewall is left untouched. When a remote run changes the firewall, a systemd timer restores the previous firewall in 120 seconds unless you confirm from a **new SSH session**:

```bash
sudo vm-init confirm-firewall
```

The confirmation instruction appears immediately; you can confirm while other setup tasks continue. The new session proves that reconnecting still works. vm-init detects SSH through the invoking process when sudo filters `SSH_CONNECTION`; if your environment prevents that detection, pass `sudo --preserve-env=SSH_CONNECTION`. Set `VM_INIT_FIREWALL_CONFIRM_SECONDS` to change the window. UFW must be able to schedule its rollback before remote changes begin. Only rules tagged `vm-init` are removed when deleted from YAML; unrelated rules are preserved. Verification checks complete rules, actions, direction, address families, default policies, and stale managed rules.

```yaml
ufw:
  enabled: true
  ipv6: true
  defaults: {incoming: deny, outgoing: allow}
  allow: [OpenSSH, 443/tcp]
```

DNS activation saves the previous files, resolver symlink, service state, and per-link settings. Failed activation restores them automatically. The original snapshot is retained for offline recovery:

```bash
sudo vm-init repair dns
sudo vm-init repair dns --with-fallback
# Existing installations may also use the compatibility command:
sudo vm-init-recover-dns --with-fallback
```

`--with-fallback` permits temporary public DNS if restoring the saved configuration does not restore resolution. `--iface` and `--fallback "1.1.1.1 9.9.9.9"` remain available. Recovery is reported as drift on subsequent applies. Disable DNS management to stop managing the recovered settings, or use `apply --only dns --restore-config` to activate the selected DNS configuration again.

```yaml
dns:
  enabled: true
  server: https://base.dns.mullvad.net/dns-query
  listen_address: 127.0.0.1
  listen_port: 5353
  bootstrap: [9.9.9.9, 149.112.112.112]
```

DNS verification checks the effective proxy configuration and system resolver routing, issues a direct query to the local proxy, and separately checks ordinary name resolution. Listening on a port or resolving a cached hostname alone is not treated as proof of the requested DNS setup.

For Fail2ban, the supported jail is `sshd`; configure it under `fail2ban.jails.sshd.enabled`. The shipped YAML documents ban time, retry limits, ignored addresses, and ban action. Inspect failures with `systemctl status fail2ban` or `journalctl -u fail2ban`.

## Administration and automation

```bash
sudo vm-init setup --yes --user alice --features shell,docker,python
sudo vm-init apply --config /etc/vm-init/team.yml --user alice,bob --fail-fast
sudo vm-init status --json --config /etc/vm-init/team.yml > status.json
```

`--yes` accepts the setup plan for automation. Existing `apply` and bare invocations remain noninteractive. `status --json` emits one JSON object on stdout and diagnostics on stderr. Schema version 1 includes the run ID, configuration fingerprint, and each module's status, desired management state, observed state, elapsed time, and last outcome. Exit 0 means no module failed; exit 1 means invalid input, failed work, or failed verification. Warnings and pending next steps are represented in the result.

Mutating runs use one machine lock. Package-manager waits use POSIX record locks and APT's native lock timeout. Runs save their exact configuration, selected accounts, and retry options under `/var/lib/vm-init/runs/<run-id>/`; saved configurations are private to root. Summaries print a correctly quoted retry command, including paths containing spaces. `repair failed` uses the most recent saved failure set, including selected modules left unfinished by `--fail-fast` or an interruption.

Normal apply runs log to `/var/log/vm-init-<timestamp>.log`. Use `--log-file <path>` or `--no-log`. Plans never create system logs; status logs only when explicitly requested. Useful environment settings:

| Setting | Default |
| --- | --- |
| `VM_INIT_MIN_DISK_MB` | 2048; 0 disables the disk-space preflight |
| `VM_INIT_APT_LOCK_TIMEOUT` | 1800 seconds |
| `VM_INIT_CMD_TIMEOUT` | 900 seconds for wrapped external commands; 0 disables it |
| `VM_INIT_PROGRESS_INTERVAL` | 15 seconds between progress messages |
| `VM_INIT_UPDATE_CHECK` | 1; 0 disables release notices |
| `NO_COLOR` | Set to disable terminal colors |

## Other installation layouts and updates

The managed installer is recommended. A standalone bundle remains available; prepare its configuration tools before the first preview:

```bash
(
set -e
bundle_dir=$(mktemp -d)
trap 'rm -rf "$bundle_dir"' EXIT
curl -fsSL https://github.com/wagga40/vm-init/releases/latest/download/vm-init -o "$bundle_dir/vm-init"
curl -fsSL https://github.com/wagga40/vm-init/releases/latest/download/vm-init.sha256 -o "$bundle_dir/vm-init.sha256"
(cd "$bundle_dir" && sha256sum -c vm-init.sha256)
sudo install -m 0755 "$bundle_dir/vm-init" /usr/local/sbin/vm-init
sudo vm-init prepare
sudo vm-init setup
)
```

The bundle includes offline DNS recovery and default configuration. From a checkout, use `sudo ./vm-init.sh prepare`, then `sudo ./vm-init.sh setup` or `./vm-init.sh plan --config ./vm-init.yml`.

`update` replaces an installed bundle after checksum and syntax verification; a managed tarball installation uses its installer. A local checkout fetches its upstream and fast-forwards only if the working tree is clean and a tracking branch exists. It refuses detached or divergent checkouts. `update` is an explicit mutation and cannot be combined with plan/status flags.

**Upgrading from 1.8:** account selection now defaults to the invoking user, not root and everyone else. Use `--all-users` if that is intended. Existing untagged firewall rules and aliases previously appended to `config.fish` cannot safely be distinguished from administrator customizations, so they are preserved; review them during migration. An enabled module remains responsible only for its managed settings.

## Development and verification

```bash
shellcheck --external-sources --source-path=modules vm-init.sh modules/*.sh scripts/*.sh
bats tests/unit tests/integration
task package
task verify
task build-single
task verify-single
```

Tests cover checksum rejection, read-only mode conflicts, real competing POSIX locks, kernel parameter removal, firewall matching and ownership, DNS rollback, configuration validation, saved retries, account targeting, CLI workflows, and bundle recovery. Update tests use deterministic release responses.

CI runs lint, tests, real Ubuntu install checks, and live firewall/DNS checks in isolated Ubuntu 24.04 and 26.04 containers. The service checks cover application profiles, repeated resolver entries, SSH confirmation, and automatic rollback. Full machine reboot behavior should additionally be exercised on disposable Ubuntu machines before a release. Requires Ubuntu, Bash 4+, and root for system changes. `prepare` installs missing configuration prerequisites from APT and, when needed, a pinned, checksum-verified yq binary; preview and status never install dependencies.
