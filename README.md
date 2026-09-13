# vm-init

[![CI](https://github.com/wagga40/vm-init/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/wagga40/vm-init/actions/workflows/ci.yml)

Set up an Ubuntu development machine with guided configuration or repeatable YAML.
The defaults install useful packages and configure Fish. Docker, Python tools,
networking, security, and additional tools are opt-in.

## Get started

```bash
curl -fsSL https://raw.githubusercontent.com/wagga40/vm-init/main/scripts/install.sh | sudo bash
sudo vm-init
```

The first run prepares missing configuration tools, asks which accounts and
features to configure, previews the changes, and applies them after confirmation.
Later runs use the saved configuration.

vm-init keeps its code, configuration, state, and logs under `/opt/vm-init`.
Edit `/opt/vm-init/config/vm-init.yml` to change the saved settings. Managed services
and user shell files stay in their usual system and home directories.

## Everyday commands

| Command | Purpose | Equivalent flags |
| --- | --- | --- |
| `sudo vm-init` | Configure on first run; apply saved settings afterward | `run`, `apply`, `--apply`, `-a` |
| `sudo vm-init plan` | Preview without system changes | `--plan`, `-p`, `--dry-run` |
| `sudo vm-init status` | Verify settings and report drift | `--status`, `-s`, `--verify` |
| `sudo vm-init update` | Update vm-init itself | `--update`, `-u` |
| `sudo vm-init repair failed` | Retry failed or interrupted work | `--repair failed`, `-r failed` |
| `sudo vm-init repair dns` | Restore DNS offline | `--repair dns`, `-r dns` |

Use `vm-init help` for all actions and options. Actions accept a command word,
a long flag, and a short flag; parameters use flags such as `--config`/`-c`
and `--user`/`-U`. Flags work before or after the action.

```bash
sudo vm-init --user root,alice,bob
sudo vm-init plan --config ./team.yml --only shell,docker
sudo vm-init --config ./team.yml --no-upgrade
sudo vm-init status --json
```

Accounts share one configuration. CLI selection overrides `users: [...]` in YAML;
otherwise vm-init uses the invoking sudo user or the current account, including
root. `--all-users` explicitly selects root and all eligible human accounts.
Accounts must already exist.

For unattended first-run configuration:

```bash
sudo vm-init --yes --user root,alice --features shell,docker
```

Changes made outside vm-init are preserved and reported as drift. To restore
selected settings, preview and then apply with `--restore-config`.

## Single-file version

Download and verify the bundle, then run it. Its first normal run installs itself
under `/opt/vm-init` and starts the same configuration flow:

```bash
(
set -e
bundle_dir=$(mktemp -d)
trap 'rm -rf "$bundle_dir"' EXIT
curl -fsSL https://github.com/wagga40/vm-init/releases/latest/download/vm-init -o "$bundle_dir/vm-init"
curl -fsSL https://github.com/wagga40/vm-init/releases/latest/download/vm-init.sha256 -o "$bundle_dir/vm-init.sha256"
(cd "$bundle_dir" && sha256sum -c vm-init.sha256)
chmod +x "$bundle_dir/vm-init"
sudo "$bundle_dir/vm-init"
)
```

From a checkout, run `sudo ./vm-init.sh`. No separate setup or preparation command
is needed. Preview and help commands never install anything.

## Documentation

- [Configuration and features](docs/configuration.md)
- [Installation, updates, automation, and recovery](docs/operations.md)
- [Development and verification](docs/development.md)

Requires Ubuntu and Bash 4+. System changes require root.
