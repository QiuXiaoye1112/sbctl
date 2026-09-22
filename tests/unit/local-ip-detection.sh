#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

SBCTL_TESTING=1 source ./sbctl.sh

original_command_exists=$(declare -f command_exists)
command_exists() { [[ $1 == ifconfig ]]; }
ifconfig() {
  printf '%s\n' \
    'eth0      Link encap:Ethernet  HWaddr 02:42:AC:11:00:02' \
    '          inet addr:192.0.2.10  Bcast:192.0.2.255  Mask:255.255.255.0' \
    '          inet6 addr: 2001:db8::10/64 Scope:Global' \
    'docker0   Link encap:Ethernet  HWaddr 02:42:00:00:00:00' \
    '          inet addr:172.17.0.1  Bcast:172.17.255.255  Mask:255.255.0.0' \
    'lo        Link encap:Local Loopback' \
    '          inet addr:127.0.0.1  Mask:255.0.0.0' \
    'ens3: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500' \
    '        inet 198.51.100.20  netmask 255.255.255.0  broadcast 198.51.100.255' \
    '        inet6 2001:db8::20%ens3  prefixlen 64  scopeid 0x0<global>' \
    '        inet6 fe80::20%ens3  prefixlen 64  scopeid 0x20<link>'
}

rows=$(detect_local_ips)
grep -Fq $'192.0.2.10 (IPv4)\t192.0.2.10\teth0' <<<"$rows"
grep -Fq $'2001:db8::10 (IPv6)\t2001:db8::10\teth0' <<<"$rows"
grep -Fq $'198.51.100.20 (IPv4)\t198.51.100.20\tens3' <<<"$rows"
grep -Fq $'2001:db8::20 (IPv6)\t2001:db8::20\tens3' <<<"$rows"
[[ $rows != *172.17.0.1* && $rows != *127.0.0.1* && $rows != *fe80::* ]]
grep -Fq 'iproute2' alpine/install.sh

eval "$original_command_exists"
printf 'local IP detection checks passed.\n'
