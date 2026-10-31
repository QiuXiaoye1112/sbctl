#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

version=$(SBCTL_TESTING=1 SBCTL_BUILD_COMMIT=development bash ./sbctl.sh version)
[[ $version == 'sbctl 0.5.0' ]]

help=$(SBCTL_TESTING=1 bash ./sbctl.sh help)
grep -Fq 'sbctl inbound add' <<<"$help"
! grep -Fq 'sbctl inbound disable' <<<"$help"
! grep -Fq 'sbctl inbound enable' <<<"$help"
grep -Fq 'sbctl config check|show|edit' <<<"$help"
grep -Fq 'sbctl traffic period set <日> <时:分>' <<<"$help"
grep -Fq 'sbctl traffic limit set <标签> <GB> <重置日>' <<<"$help"
grep -Fq 'sbctl outbound rule list [入站]' <<<"$help"
grep -Fq 'sbctl outbound rule add <入站> <suffix|exact> <域名[,域名...]> <出站>' <<<"$help"
grep -Fq 'sbctl outbound rule delete [入站] [suffix|exact] [域名]' <<<"$help"
grep -Fq '支持入站: AnyTLS、Hysteria2、SOCKS5、HTTP' <<<"$help"

printf 'CLI smoke checks passed.\n'

if [[ -x dist/sbctl ]]; then
  recorded_commit=$(sed -n 's/^readonly SBCTL_BUILD_COMMIT="\([^"]*\)"/\1/p' dist/sbctl | head -1)
  [[ $(SBCTL_TESTING=1 bash ./dist/sbctl version) == "sbctl 0.5.0 (commit $recorded_commit)" ]]
  SBCTL_TESTING=1 bash ./dist/sbctl help | grep -Fq 'sbctl inbound add'
fi
