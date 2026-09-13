# Configuration

## Files and accounts

Configuration precedence is `--config <path>`, the saved
`/opt/vm-init/config/vm-init.yml`, then a separate `./vm-init.yml` in the current
directory. Shipped and embedded defaults seed the first-run wizard. vm-init prints
the selected source; an invalid or unreadable configuration is an error.
Legacy configurations remain readable until migration.

`vm-init write-default-config` (`--write-default-config`, `-w`) exports defaults
to `./vm-init.yml` without overwriting an existing file. The shipped
[vm-init.yml](../vm-init.yml) documents all supported fields.

```yaml
users: [root, alice, bob]
apt:
  enabled: true
  packages:
    extra: [jq, git, curl]
shell:
  enabled: true
  default_shell: fish
  fisher: false
  tide: false
  zoxide: true
  aliases:
    ll: ls -ahlF --group-directories-first
docker:
  enabled: true
```

`--user root,alice` or repeated `--user`/`-U` flags override YAML account selection.
`--all-users` includes root and human accounts with login shells; it cannot be
combined with `--user`. The fallback is the invoking sudo user, then the current
account. Docker group membership is applied only to selected non-root accounts.

An omitted or disabled module is unmanaged for that run. Disabling a module does
not uninstall packages or stop an existing service.

## Features

| Module | Default | Manages |
| --- | --- | --- |
| `apt` | on | Packages and dependencies |
| `shell` | on | Fish or Bash, aliases, zoxide/direnv, Fisher/Tide |
| `docker` | off | Engine, Buildx, Compose, group membership |
| `python` | off | Shared pipx tools |
| `github_tools` | off | GitHub CLI and act |
| `github_releases` | off | Configured release binaries |
| `yazi` | off | Yazi and its APT repository |
| `ufw` | off | Firewall policies and vm-init-owned rules |
| `fail2ban` | off | Fail2ban and the SSH jail |
| `dns` | off | Encrypted DNS and resolver routing |
| `kernel` | off | The `mitigations_off` boot parameter |

Guided features are `shell`, `docker`, `python`, and `tools` (GitHub release tools).
Use `setup` or `--features` to reopen configuration; existing unrelated settings
are preserved. YAML exposes the full module selection.

Shell files belong to their account: Fish uses `~/.config/fish/conf.d/90-vm-init.fish`;
Bash uses `~/.config/vm-init/bash.sh`, sourced by `.bashrc`. Other startup files
are preserved. Ubuntu's `batcat` is used when `bat` is unavailable.

```yaml
github_releases:
  enabled: true
  generic:
    - repo: owner/repo
      asset_pattern: "tool_{version}_Linux_{arch}.tar.gz"
      binary: tool
      arch_map: {amd64: x86_64, arm64: arm64}
```

Available checksums must match before installation. Upstreams without checksum
sidecars produce a warning. `--no-upgrade` skips updates for installed software
while still installing missing dependencies.

## Repeat runs

vm-init compares YAML, live settings, and the last verified baseline. Matching
settings are left alone; configuration changes are applied when safe. External
edits and conflicting changes are preserved and reported as drift.

```bash
sudo vm-init plan --only shell,ufw --restore-config --no-upgrade
sudo vm-init --only shell,ufw --restore-config --no-upgrade
sudo vm-init status --only shell,ufw
```

Restoration respects selected modules and accounts and preserves unrelated
settings. `--force` also permits restoration and retains its broader software
reinstallation behavior. Plans and status never advance baselines.
