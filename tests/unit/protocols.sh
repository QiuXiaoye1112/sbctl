#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"
SBCTL_TESTING=1 source ./sbctl.sh

tls='{"enabled":true,"server_name":"example.com","certificate_path":"/cert.crt","key_path":"/cert.key"}'

json=''
protocol_build_anytls json anytls-test 0.0.0.0 443 alice secret "$tls"
jq -e '.type=="anytls" and .tag=="anytls-test" and .users[0].password=="secret" and .tls.enabled==true' <<<"$json" >/dev/null

protocol_build_vless json vless-test 0.0.0.0 8443 alice 550e8400-e29b-41d4-a716-446655440000 '' '' '{"type":"ws","path":"/ws"}'
jq -e '.type=="vless" and (has("tls")|not) and .transport.type=="ws" and .users[0].flow==""' <<<"$json" >/dev/null

protocol_build_trojan json trojan-test 0.0.0.0 9443 alice secret "$tls" null
jq -e '.type=="trojan" and .tls.enabled==true and (has("transport")|not)' <<<"$json" >/dev/null

protocol_build_proxy json socks socks-test 127.0.0.1 1080 '' ''
jq -e '.type=="socks" and .users==[]' <<<"$json" >/dev/null

hy2_build json hy2-test 0.0.0.0 10443 alice secret 100 200 salamander "$tls"
jq -e '.type=="hysteria2" and .up_mbps==100 and .down_mbps==200 and .obfs.type=="salamander"' <<<"$json" >/dev/null

protocol_capability vless reality
! protocol_capability hysteria2 reality

printf 'protocol builder unit checks passed.\n'
