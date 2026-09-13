#!/usr/bin/env bash
# Real firewall and resolver tests, restricted to a disposable container.
set -euo pipefail
service_test_failure() {
  local line="$1" failed_command="$2" log
  echo "Service check failed at line $line: $failed_command" >&2
  for log in drift.log rollback.log unchanged-dns.log fail2ban-drift.log; do
    if [[ -f "$log" ]]; then cat "$log" >&2; fi
  done
}
trap 'service_test_failure "$LINENO" "$BASH_COMMAND"' ERR
[[ -f /.dockerenv && "${VM_INIT_SERVICE_TEST:-}" == 1 ]] || {
  echo 'Run only in the dedicated service-test container.' >&2
  exit 1
}
export VM_INIT_UPDATE_CHECK=0
export LC_ALL=C
mkdir -p /work
cp /src/vm-init.sh /src/VERSION /work/
cp -a /src/modules /work/
cd /work

# Docker bind-mounts resolv.conf. Give this container its own replaceable file.
cp /etc/resolv.conf /tmp/container-resolv.conf
umount /etc/resolv.conf
cp /tmp/container-resolv.conf /etc/resolv.conf
# Seed an earlier DNS setting to exercise resolved's list accumulation.
bootstrap=$(awk '/^nameserver / {print $2; exit}' /etc/resolv.conf)
mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNS=%s\n' "$bootstrap" > /etc/systemd/resolved.conf.d/10-provider.conf
systemctl restart systemd-resolved

cat > service-test.yml <<'YAML'
ufw:
  enabled: true
  ipv6: true
  defaults: {incoming: deny, outgoing: allow}
  allow: [OpenSSH, 51820/udp]
dns:
  enabled: true
  server: https://dns.google/dns-query
  listen_address: 127.0.0.1
  listen_port: 5353
  bootstrap: [8.8.8.8, 8.8.4.4]
YAML

ufw allow OpenSSH
ufw allow 51820/udp
ufw insert 1 reject from 195.178.110.30 comment 'by Fail2Ban after 5 attempts against sshd'
ufw --force enable
ufw status verbose
./vm-init.sh apply --config service-test.yml --only ufw --no-log
./vm-init.sh status --config service-test.yml --only ufw
ufw status | grep -q '195.178.110.30'

# Exercise confirmation and the real systemd rollback timer.
SSH_CONNECTION='198.51.100.1 4000 192.0.2.1 22' \
  ./vm-init.sh apply --config service-test.yml --only ufw --no-log
[[ ! -f /opt/vm-init/state/firewall-pending ]]
sed 's/51820\/udp]/51820\/udp, 8081\/tcp]/' service-test.yml > confirmation-test.yml
SSH_CONNECTION='198.51.100.1 4000 192.0.2.1 22' \
  ./vm-init.sh apply --config confirmation-test.yml --only ufw --no-log
SSH_CONNECTION='198.51.100.1 4001 192.0.2.1 22' ./vm-init.sh confirm-firewall
[[ ! -f /opt/vm-init/state/firewall-pending ]]
sed 's/51820\/udp]/51820\/udp, 8080\/tcp]/' service-test.yml > rollback-test.yml
SSH_CONNECTION='198.51.100.1 4002 192.0.2.1 22' VM_INIT_FIREWALL_CONFIRM_SECONDS=5 \
  ./vm-init.sh apply --config rollback-test.yml --only ufw --no-log
for _ in {1..20}; do
  [[ -f /opt/vm-init/state/firewall-pending ]] || break
  sleep 1
done
[[ ! -f /opt/vm-init/state/firewall-pending ]]
if ufw status | grep -q '8080/tcp'; then echo 'Firewall timer did not restore previous rules' >&2; exit 1; fi
ufw status | grep -q '195.178.110.30'

# Reconcile the temporary SSH-preservation rule from the simulated session.
./vm-init.sh apply --config service-test.yml --only ufw --no-log

./vm-init.sh apply --config service-test.yml --only dns --no-log
resolvectl dns
./vm-init.sh status --config service-test.yml --only dns
./vm-init.sh apply --config service-test.yml --only dns --no-log
./vm-init.sh status --json --config service-test.yml > status.json
jq -e 'all(.modules[]; .status != "failed")' status.json

# Foreign DNS drift is preserved; explicit restoration still verifies and rolls back on conflict.
cp /etc/systemd/resolved.conf.d/99-vm-init-dnsproxy.conf /tmp/expected-dns.conf
printf '[Resolve]\nDNS=127.0.0.1:5354\n' > /etc/systemd/resolved.conf.d/zz-foreign.conf
# Activate the foreign setting before testing runtime drift. An unchanged
# apply intentionally leaves resolved running with its current configuration.
systemctl restart systemd-resolved
./vm-init.sh apply --config service-test.yml --only dns --no-log > drift.log 2>&1
grep -q 'configuration drift' drift.log
if ./vm-init.sh status --config service-test.yml --only dns --no-log; then
  echo 'DNS drift unexpectedly passed status' >&2; exit 1
fi
if ./vm-init.sh apply --restore-config --config service-test.yml --only dns --no-log > rollback.log 2>&1; then
  cat rollback.log
  echo 'Unexpected DNS server was accepted' >&2
  exit 1
fi
cat rollback.log
grep -q 'Effective global DNS differs' rollback.log
grep -q 'Previous DNS configuration restored' rollback.log
if grep -q 'DNS now goes through dnsproxy' rollback.log; then echo 'Rolled-back DNS reported as successful' >&2; exit 1; fi
cmp /etc/systemd/resolved.conf.d/99-vm-init-dnsproxy.conf /tmp/expected-dns.conf
rm /etc/systemd/resolved.conf.d/zz-foreign.conf
systemctl restart systemd-resolved
./vm-init.sh status --config service-test.yml --only ufw,dns
printf 'Real firewall, DNS, confirmation and rollback checks passed.\n'

# An unchanged DNS apply must leave file metadata and service processes alone.
dns_before=$(stat -c '%i:%Y:%Z' /etc/systemd/system/dnsproxy.service)
dns_pid=$(systemctl show dnsproxy -p MainPID --value)
resolved_pid=$(systemctl show systemd-resolved -p MainPID --value)
./vm-init.sh apply --config service-test.yml --only dns --no-upgrade --no-log > unchanged-dns.log
[[ "$(stat -c '%i:%Y:%Z' /etc/systemd/system/dnsproxy.service)" == "$dns_before" ]]
[[ "$(systemctl show dnsproxy -p MainPID --value)" == "$dns_pid" ]]
[[ "$(systemctl show systemd-resolved -p MainPID --value)" == "$resolved_pid" ]]
grep -q 'DNS configuration unchanged' unchanged-dns.log

cat > fail2ban-test.yml <<'YAML'
fail2ban:
  enabled: true
  bantime: 1h
  findtime: 10m
  maxretry: 5
  backend: systemd
  banaction: ufw
  ignoreip: [127.0.0.1/8, '::1']
  jails: {sshd: {enabled: true}}
YAML
./vm-init.sh apply --config fail2ban-test.yml --no-log
./vm-init.sh status --config fail2ban-test.yml --no-log
fail2ban_pid=$(systemctl show fail2ban -p MainPID --value)
fail2ban_before=$(stat -c '%i:%Y:%Z' /etc/fail2ban/jail.d/vm-init.local)
./vm-init.sh apply --config fail2ban-test.yml --no-upgrade --no-log
[[ "$(systemctl show fail2ban -p MainPID --value)" == "$fail2ban_pid" ]]
[[ "$(stat -c '%i:%Y:%Z' /etc/fail2ban/jail.d/vm-init.local)" == "$fail2ban_before" ]]
fail2ban-client set sshd maxretry 9
./vm-init.sh apply --config fail2ban-test.yml --no-log > fail2ban-drift.log
grep -q 'configuration drift' fail2ban-drift.log
[[ "$(fail2ban-client get sshd maxretry)" == 9 ]]
./vm-init.sh apply --restore-config --config fail2ban-test.yml --no-log
[[ "$(fail2ban-client get sshd maxretry)" == 5 ]]
printf 'Configuration reconciliation service checks passed.\n'
