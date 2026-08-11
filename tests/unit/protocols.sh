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

# Hysteria2 without QUIC obfuscation must pass an initialized empty password.
# Bash 5.2 treats an uninitialized `local` as unset under `set -u`, which used
# to terminate the real interactive flow before hy2_build was called.
choose() {
  local __var=$1 prompt=$2
  case $prompt in
    "选择入站协议") printf -v "$__var" '%s' 3 ;;
    "端口模式") printf -v "$__var" '%s' 1 ;;
    "QUIC 混淆") printf -v "$__var" '%s' 1 ;;
  esac
}
prompt_tag() { printf -v "$1" '%s' hy2-no-obfs; }
prompt_value() {
  local __var=$1 prompt=$2
  case $prompt in
    "监听地址") printf -v "$__var" '%s' 127.0.0.1 ;;
    "用户名称") printf -v "$__var" '%s' alice ;;
  esac
}
prompt_port() { printf -v "$1" '%s' 10443; }
build_certificate_tls() {
  printf -v "$1" '%s' '{"enabled":true,"server_name":"example.com","certificate_path":"/cert.crt","key_path":"/cert.key"}'
  [[ -z ${2-} ]] || printf -v "$2" '%s' example.com
}
prompt_secret() { printf -v "$1" '%s' secret; }
prompt_optional_positive_int() { printf -v "$1" '%s' ''; }

inbound=''; host=''; public=''; hop=''
build_inbound inbound host public hop
jq -e '.type=="hysteria2" and (has("obfs")|not)' <<<"$inbound" >/dev/null

# An unauthenticated SOCKS inbound leaves the optional username and password
# empty; both still need initialized values under Bash 5.2 `set -u` semantics.
choose() {
  local __var=$1 prompt=$2
  case $prompt in
    "选择入站协议") printf -v "$__var" '%s' 5 ;;
  esac
}
prompt_public_host() { printf -v "$1" '%s' 203.0.113.10; }
prompt_optional() { printf -v "$1" '%s' ''; }
inbound=''; host=''; public=''; hop=''
build_inbound inbound host public hop
jq -e '.type=="socks" and .users==[]' <<<"$inbound" >/dev/null

printf 'protocol builder unit checks passed.\n'
