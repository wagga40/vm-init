#!/usr/bin/env bash
# Real firewall and resolver tests, restricted to a disposable container.
set -euo pipefail
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
SSH_CONNECTION='198.51.100.1 4001 192.0.2.1 22' ./vm-init.sh confirm-firewall
[[ ! -f /var/lib/vm-init/firewall-pending ]]
sed 's/51820\/udp]/51820\/udp, 8080\/tcp]/' service-test.yml > rollback-test.yml
SSH_CONNECTION='198.51.100.1 4002 192.0.2.1 22' VM_INIT_FIREWALL_CONFIRM_SECONDS=5 \
  ./vm-init.sh apply --config rollback-test.yml --only ufw --no-log
for _ in {1..20}; do
  [[ -f /var/lib/vm-init/firewall-pending ]] || break
  sleep 1
done
[[ ! -f /var/lib/vm-init/firewall-pending ]]
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

# A later foreign DNS setting must still fail verification and roll back.
cp /etc/systemd/resolved.conf.d/99-vm-init-dnsproxy.conf /tmp/expected-dns.conf
printf '[Resolve]\nDNS=127.0.0.1:5354\n' > /etc/systemd/resolved.conf.d/zz-foreign.conf
if ./vm-init.sh apply --config service-test.yml --only dns --no-log > rollback.log 2>&1; then
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
