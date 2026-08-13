#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

version=$(SBCTL_TESTING=1 bash ./sbctl.sh version)
[[ $version == 'sbctl 0.4.6' ]]

help=$(SBCTL_TESTING=1 bash ./sbctl.sh help)
grep -Fq 'sbctl inbound add' <<<"$help"
grep -Fq 'sbctl config check|show|edit' <<<"$help"
grep -Fq 'sbctl outbound rule list [入站]' <<<"$help"
grep -Fq 'sbctl outbound rule add [入站] [suffix|exact] [域名] [出站]' <<<"$help"
grep -Fq 'sbctl outbound rule delete [入站]' <<<"$help"
grep -Fq '支持入站: AnyTLS、VLESS、Hysteria2、Trojan、SOCKS5、HTTP' <<<"$help"

printf 'CLI smoke checks passed.\n'

if [[ -x dist/sbctl ]]; then
  [[ $(SBCTL_TESTING=1 bash ./dist/sbctl version) == 'sbctl 0.4.6' ]]
  SBCTL_TESTING=1 bash ./dist/sbctl help | grep -Fq 'sbctl inbound add'
fi
