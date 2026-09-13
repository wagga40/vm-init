# Development

```bash
shellcheck --external-sources --source-path=modules vm-init.sh modules/*.sh scripts/*.sh
bats tests/unit tests/integration
task package
task verify
task build-single
task verify-single
```

The tarball includes code, default configuration, and documentation. The bundle
embeds shared helpers, every module, default configuration, and offline recovery.
Both distributions use the same CLI and installation lifecycle.

Unit tests run without root. Integration tests requiring installation or system
changes run as root on disposable Ubuntu systems. Test helpers isolate state,
installation paths, and release responses. Never run live service tests on a
working machine.

CI covers Ubuntu 22.04 and 24.04, including jq 1.6 compatibility. Live firewall and
DNS tests run in isolated Ubuntu 24.04 and 26.04 containers and exercise drift,
SSH confirmation, and rollback. Release workflows validate the requested tag
before building and publishing checksum-verified artifacts. Test complete reboot
behavior on a disposable VM before release.
