# vm-init

A highly opinionated, config-driven tool for provisioning Ubuntu machines. It reads `vm-init.yml` and executes modular install scripts to set up a carefully curated environment.

## What it installs

| Module | What |
|--------|------|
| **apt** | Fish shell, editors, build tools, CLI utilities, dev tools |
| **ufw** | Firewall — deny incoming, allow outgoing, permit listed services |
| **dns** | DNS privacy via dnsproxy (DoH/DoT) with systemd-resolved |
| **docker** | Docker engine + compose plugin |
| **python** | pdm, poetry, uv, pre-commit via pipx |
| **github-tools** | GitHub CLI (`gh`), act (local GitHub Actions) |
| **github-releases** | lazydocker, xplr, task, bandwhich, vortix, somo |
| **shell** | Fish as default, Fisher + Tide, aliases, direnv |

Each module can be toggled on/off or customized in `vm-init.yml`.

## Install

Two install paths are published with every release: a **single-file bundle** (recommended, simplest) and the classic **tarball** (retains the full repo layout on disk).

### Single-file bundle (recommended)

One self-contained shell script with `_common.sh`, all modules, and the default `vm-init.yml` inlined — no extraction, no repo checkout:

```bash
# Download and pin to /usr/local/sbin
curl -fsSL https://github.com/wagga40/vm-init/releases/latest/download/vm-init \
  -o /usr/local/sbin/vm-init
sudo chmod +x /usr/local/sbin/vm-init

# Preview and run with the embedded default config
sudo vm-init --dry-run
sudo vm-init

# (Optional) materialize the default config next to you so you can edit it
vm-init --write-default-config             # writes ./vm-init.yml (no sudo needed)
$EDITOR vm-init.yml
sudo vm-init --config "$(pwd)/vm-init.yml" # run with your edits
# ...or promote it to a standard location so future runs auto-pick-up:
sudo install -Dm 0644 vm-init.yml /etc/vm-init/vm-init.yml
```

The bundle runs with the embedded default when no `/etc/vm-init/vm-init.yml` and no `--config` are supplied, so a bare `sudo vm-init` works immediately — customize only when you want to.

### Tarball

Fetches the release tarball, verifies its sha256, extracts to `/opt/vm-init`, and symlinks `vm-init` (and `vm-init-recover-dns`) under `/usr/local/sbin`:

```bash
curl -fsSL https://raw.githubusercontent.com/wagga40/vm-init/main/scripts/install.sh \
  | sudo bash
```

See `scripts/install.sh --help` for all options (including `--version` to pin a specific release).

After install, run:

```bash
sudo vm-init --dry-run   # preview
sudo vm-init             # execute
```

## Usage

```bash
sudo vm-init                          # full run with default config
sudo vm-init --dry-run                # preview every module's actions, no changes
sudo vm-init --list-modules           # table of modules + enabled state
vm-init --write-default-config        # write embedded default to ./vm-init.yml (no sudo)
sudo vm-init --only dns               # run just the DNS module (e.g. after recovery)
sudo vm-init --skip docker,github_releases
sudo vm-init --config /path/to.yml    # custom config
sudo vm-init --force                  # reinstall everything
sudo vm-init --verbose                # stream full command output
sudo vm-init --log-file /tmp/run.log  # custom log path (default: /var/log/vm-init-<ts>.log)
```

By default every run mirrors stdout/stderr to `/var/log/vm-init-<timestamp>.log`. Pass `--no-log` to disable. Every run prints a structured summary at the end (ok / skipped / warned / failed counts).

### Config precedence

1. `--config <path>` (explicit override)
2. `/etc/vm-init/vm-init.yml` (system-wide override — survives upgrades)
3. `<script dir>/vm-init.yml` (default shipped with the tarball installation)
4. Embedded default YAML inlined in the single-file bundle (materialized to a
   temp file when neither of the above exists, no-op for the tarball install)

## Configuration

Edit `vm-init.yml` to customize. The config uses categories with sensible defaults:

```yaml
apt:
  enabled: true
  packages:
    cli: [bat, lsd, tree, jq, ripgrep, fzf]
    extra: [my-custom-package]

docker:
  enabled: false  # disable a whole category
```

Adding a new GitHub release tool (standard tarball) requires only a config entry:

```yaml
github_releases:
  generic:
    - repo: owner/repo
      asset_pattern: "tool_{version}_Linux_{arch}.tar.gz"
      binary: tool
      arch_map: { amd64: x86_64, arm64: arm64 }
```

## DNS (DoH/DoT)

The `dns` module installs [dnsproxy](https://github.com/AdguardTeam/dnsproxy) and configures `systemd-resolved` to route all DNS queries through it. Default config uses Mullvad DNS-over-HTTPS:

```yaml
dns:
  enabled: true
  server: https://base.dns.mullvad.net/dns-query
  listen_address: 127.0.0.1
  listen_port: 5353
  bootstrap:
    - 9.9.9.9
    - 149.112.112.112
```

| Key | Purpose |
|-----|---------|
| `server` | DoH (`https://...`) or DoT (`tls://...`) upstream URL |
| `listen_address` | Local address dnsproxy binds to |
| `listen_port` | Local port dnsproxy listens on (default 5353, avoids conflict with resolved stub on 53) |
| `bootstrap` | Plain DNS servers used by dnsproxy to resolve the upstream hostname |

### How it works

1. `dnsproxy` binary is installed from GitHub releases.
2. A systemd unit (`dnsproxy.service`) starts the proxy on `listen_address:listen_port`.
3. A resolved drop-in (`/etc/systemd/resolved.conf.d/99-vm-init-dnsproxy.conf`) points `DNS=` at the local proxy.
4. `/etc/resolv.conf` is symlinked to the resolved stub.
5. Default-route network links are pinned to the local proxy via `resolvectl`.

### Troubleshooting

```bash
systemctl status dnsproxy
systemctl status systemd-resolved
ss -lunp | grep 5353
journalctl -u dnsproxy -n 50 --no-pager
resolvectl status
resolvectl query example.com
getent hosts example.com
```

Common gotchas:

- `systemd-resolved` must be installed and active. The `dns` module installs it on demand, but on very minimal images it may fail if `apt` is also disabled.
- `DNS=127.0.0.1:5353` uses `:` for port. Do not confuse with `#`, which is for TLS SNI in systemd-resolved config.
- DHCP-provided per-link DNS can override global settings. `Domains=~.` in the drop-in plus `resolvectl dns`/`resolvectl domain` on default-route links forces all queries through the local proxy.

If DNS is broken after provisioning, use the recovery script:

```bash
sudo vm-init-recover-dns --with-fallback     # when installed via scripts/install.sh
sudo modules/recover-dns.sh --with-fallback  # from a source checkout
```

This disables dnsproxy, removes custom resolved config, and restores system defaults. See `--help` for options.

## Packaging

Requires [Task](https://taskfile.dev):

```bash
task package        # creates dist/vm-init-<VERSION>.tar.gz + .sha256
task verify         # verify the latest tarball against its checksum
task build-single   # creates dist/vm-init-<VERSION>  (self-contained script)
task verify-single  # verify + bash -n the latest single-file bundle
task version        # print the current version
task clean          # remove dist/
```

Version is read from the `VERSION` file (falls back to `0.0.0-dev.g<sha>` in a git checkout without VERSION).

`task build-single` concatenates `modules/_common.sh`, every `modules/*.sh`, the orchestrator, and the default `vm-init.yml` into one shell script and sets `VM_INIT_BUNDLED=1`. At runtime that flag makes the orchestrator skip per-module `source` calls and fall back to the inlined YAML when no on-disk config is present.

Publishing a release: tag the commit with `v<VERSION>` matching the VERSION file. The release workflow in `.github/workflows/release.yml` will build **both** the tarball and the single-file bundle, rename them to unversioned asset names (so `/releases/latest/download/vm-init` always resolves), attach their sha256 sidecars, and draft release notes with install snippets for each path.

## Development

```bash
# Lint + syntax check (same as CI)
shellcheck --external-sources --source-path=modules vm-init.sh modules/*.sh scripts/*.sh
bash -n vm-init.sh

# Run the bats suite (requires bats, jq, and mikefarah yq v4 on PATH)
bats tests/unit           # pure-bash helper tests (no root / no network)
bats tests/integration    # orchestrator smoke tests via --dry-run
```

CI runs the full suite on every push / PR:

- `lint`            — shellcheck + `bash -n` on every shell file.
- `yamllint`        — sanity check on `vm-init.yml` and workflows.
- `unit-tests`      — `bats tests/unit` on ubuntu-latest.
- `integration-tests` — `bats tests/integration` inside a privileged
  `ubuntu:24.04` container, matching the target VM environment
  (`go-task` is installed so the packaging round-trip test exercises
  `task package` end-to-end).

## Requirements

- Ubuntu (any recent version) at runtime
- Root access (`sudo`)
- `curl` and `jq` (installed by apt module if missing)
- `yq` v4 from mikefarah (auto-installed by vm-init.sh if missing)
