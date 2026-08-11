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
grep -Fq 'choose answer "选择 TLS serverName/SNI"' src/certificate/core.sh
grep -Fq 'protocol_build_anytls()' src/protocols.sh
grep -Fq 'protocol_build_vless()' src/protocols.sh
grep -Fq 'protocol_build_trojan()' src/protocols.sh
grep -Fq 'hy2_build()' src/hysteria2.sh
grep -Fq '支持入站: AnyTLS、VLESS、Hysteria2、Trojan、SOCKS5、HTTP' src/menu.sh
grep -Fq 'AnyTLS、VLESS、Hysteria2、Trojan、SOCKS5、HTTP 入站' README.md
! grep -Fq 'Mixed 入站' README.md

printf 'protocol surface checks passed.\n'
