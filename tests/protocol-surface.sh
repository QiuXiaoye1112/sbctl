#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

bash -n lib/certificate.sh
bash -n lib/protocols.sh
bash -n lib/share.sh

grep -Fq 'choose choice "选择入站协议" "AnyTLS" "VLESS" "Hysteria2" "Trojan" "SOCKS5" "HTTP"' lib/protocols.sh
! grep -Fq '"Mixed(SOCKS+HTTP)"' lib/protocols.sh
grep -Fq 'anytls://' lib/share.sh
grep -Fq 'confirm "使用托管证书？" Y' lib/certificate.sh
grep -Fq 'choose answer "选择 TLS serverName/SNI"' lib/certificate.sh

printf 'protocol surface checks passed.\n'
