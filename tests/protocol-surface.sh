#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

bash -n src/certificate/core.sh
bash -n src/protocols.sh
bash -n src/share.sh
bash -n src/inbound.sh

# build_inbound now lives canonically in inbound.sh
grep -Fq 'choose choice "选择入站协议" "AnyTLS" "VLESS" "Hysteria2" "Trojan" "SOCKS5" "HTTP"' src/inbound.sh
! grep -Fq 'mixed)' src/inbound.sh
grep -Fq 'anytls://' src/share.sh
grep -Fq 'confirm "使用托管证书？" Y' src/certificate/core.sh
grep -Fq 'choose answer "选择 TLS serverName/SNI"' src/certificate/core.sh

printf 'protocol surface checks passed.\n'
