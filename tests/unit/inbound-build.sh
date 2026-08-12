#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

SBCTL_TESTING=1 \
SBCTL_CONFIG_DIR="$TMP/config" \
SBCTL_CONFIG_FILE="$TMP/config/config.json" \
SBCTL_META_FILE="$TMP/meta.json" \
SBCTL_CERT_DIR="$TMP/config/certs" \
SBCTL_LOCK_FILE="$TMP/lock" \
source ./sbctl.sh
write_default_config

case_protocol= case_security= case_transport= case_hop_mode= case_obfs=
case_tag= case_port= case_name= case_password= case_listen= case_client_host=
case_up= case_down= case_hop_range= case_internal_port= case_ws_path=
inbound= host= public_key= hop_range=

choose() {
  local __var=$1 prompt=$2
  case $prompt in
    "选择入站协议") printf -v "$__var" '%s' "$case_protocol" ;;
    "选择 TLS 安全层")
      case $case_security in
        reality) printf -v "$__var" '%s' 1 ;;
        cert) printf -v "$__var" '%s' 2 ;;
        none) printf -v "$__var" '%s' 3 ;;
      esac
      ;;
    "传输方式")
      if [[ $case_transport == ws ]]; then printf -v "$__var" '%s' 2; else printf -v "$__var" '%s' 1; fi
      ;;
    "端口模式") printf -v "$__var" '%s' "$case_hop_mode" ;;
    "QUIC 混淆") printf -v "$__var" '%s' "$case_obfs" ;;
    *) printf -v "$__var" '%s' 1 ;;
  esac
}

prompt_tag() { printf -v "$1" '%s' "$case_tag"; }

prompt_value() {
  local __var=$1 prompt=$2
  case $prompt in
    "监听地址") printf -v "$__var" '%s' "$case_listen" ;;
    "用户名称") printf -v "$__var" '%s' "$case_name" ;;
    "WebSocket 路径") printf -v "$__var" '%s' "$case_ws_path" ;;
    "端口跳跃范围") printf -v "$__var" '%s' "$case_hop_range" ;;
    *) printf -v "$__var" '%s' '' ;;
  esac
}

prompt_port() { printf -v "$1" '%s' "$case_port"; }
prompt_public_host() { printf -v "$1" '%s' "$case_client_host"; }
prompt_optional() { printf -v "$1" '%s' "${case_username:-}"; }
prompt_secret() {
  if [[ $2 == "混淆密码" ]]; then
    printf -v "$1" '%s' "${case_obfs_password:-obfs-secret}"
  else
    printf -v "$1" '%s' "$case_password"
  fi
}
prompt_optional_positive_int() {
  case $2 in
    上行*) printf -v "$1" '%s' "$case_up" ;;
    下行*) printf -v "$1" '%s' "$case_down" ;;
    *) printf -v "$1" '%s' '' ;;
  esac
}
prompt_hy2_internal_port() { printf -v "$1" '%s' "$case_internal_port"; }

build_certificate_tls() {
  printf -v "$1" '%s' '{"enabled":true,"server_name":"cert.example.com","certificate_path":"/tmp/cert.crt","key_path":"/tmp/cert.key","min_version":"1.2"}'
  [[ -z ${2-} ]] || printf -v "$2" '%s' cert.example.com
}

build_reality_tls() {
  printf -v "$1" '%s' '{"enabled":true,"server_name":"reality.example.com","reality":{"enabled":true,"handshake":{"server":"target.example.com","server_port":8443},"private_key":"reality-private","short_id":["deadbeef"]}}'
  printf -v "$2" '%s' reality-public
}

generate_uuid() { printf '%s' '00000000-0000-0000-0000-000000000001'; }
hy2_hop_check_conflicts() { return 0; }

assert_json() {
  local expression=${!#}
  jq -e "$@" <<<"$inbound" >/dev/null || {
    printf 'assertion failed for %s: %s\n%s\n' "$case_tag" "$expression" "$inbound" >&2
    return 1
  }
}

run_build() {
  local expected_port=$case_port
  if [[ $case_expected_type == hysteria2 && $case_hop_mode == 2 ]]; then expected_port=$case_internal_port; fi
  inbound= host= public_key= hop_range=
  build_inbound inbound host public_key hop_range

  jq -e --arg type "$case_expected_type" --arg tag "$case_tag" \
    --arg listen "$case_listen" --argjson port "$expected_port" \
    '.type==$type and .tag==$tag and .listen==$listen and .listen_port==$port' <<<"$inbound" >/dev/null

  case $case_expected_type in
    vless)
      assert_json --arg name "$case_name" --arg uuid '00000000-0000-0000-0000-000000000001' \
        '(.users|length)==1 and .users[0].name==$name and .users[0].uuid==$uuid'
      ;;
    anytls|trojan|hysteria2)
      assert_json --arg name "$case_name" --arg password "$case_password" \
        '(.users|length)==1 and .users[0].name==$name and .users[0].password==$password'
      ;;
    socks|http)
      if [[ -n ${case_username:-} ]]; then
        assert_json --arg username "$case_username" --arg password "$case_password" \
          '(.users|length)==1 and .users[0].username==$username and .users[0].password==$password'
      else
        assert_json '.users==[]'
      fi
      ;;
  esac

  case $case_security in
    cert)
      assert_json '.tls.enabled==true and .tls.server_name=="cert.example.com" and .tls.certificate_path=="/tmp/cert.crt" and .tls.key_path=="/tmp/cert.key"'
      [[ $host == cert.example.com && -z $public_key ]] || return 1
      ;;
    reality)
      assert_json '.tls.enabled==true and .tls.server_name=="reality.example.com" and .tls.reality.enabled==true and .tls.reality.handshake.server=="target.example.com" and .tls.reality.handshake.server_port==8443 and .tls.reality.private_key=="reality-private" and .tls.reality.short_id[0]=="deadbeef"'
      [[ $host == reality-client.example.com && $public_key == reality-public ]] || return 1
      ;;
    none)
      assert_json 'has("tls")|not'
      [[ $host == 198.51.100.10 && -z $public_key ]] || return 1
      ;;
  esac

  if [[ ${case_transport:-tcp} == ws ]]; then
    assert_json --arg path "$case_ws_path" --arg host "$case_client_host" \
      '.transport.type=="ws" and .transport.path==$path and .transport.headers.Host==$host'
  else
    assert_json 'has("transport")|not'
  fi

  if [[ $case_expected_type == hysteria2 ]]; then
    if [[ ${case_obfs:-1} == 2 ]]; then
      assert_json '.obfs.type=="salamander" and .obfs.password=="obfs-secret"'
    else
      assert_json 'has("obfs")|not'
    fi
    if [[ -n $case_up ]]; then assert_json --argjson up "$case_up" '.up_mbps==$up'; else assert_json 'has("up_mbps")|not'; fi
    if [[ -n $case_down ]]; then assert_json --argjson down "$case_down" '.down_mbps==$down'; else assert_json 'has("down_mbps")|not'; fi
    if [[ $case_hop_mode == 2 ]]; then [[ $hop_range == "$case_hop_range" ]] || return 1; else [[ -z $hop_range ]] || return 1; fi
  else
    [[ -z $hop_range ]] || return 1
  fi
}

run_case() {
  case_tag=$1
  case_protocol=$2
  case_expected_type=$3
  case_security=$4
  case_transport=$5
  case_hop_mode=$6
  case_obfs=$7
  case_up=$8
  case_down=$9
  case_username=${10-}
  case_hop_range=${11-30000-50000}
  case_internal_port=${12-10326}
  case_ws_path=${13-/ws-test}
  case_listen='0.0.0.0'
  case_port=443
  case_name="${case_tag}-user"
  case_password="${case_tag}-password"
  case_obfs_password=obfs-secret
  case_client_host=198.51.100.10
  if [[ $case_security == cert ]]; then case_client_host=cert.example.com; fi
  if [[ $case_security == reality ]]; then case_client_host=reality-client.example.com; fi
  run_build
  printf 'passed %s\n' "$case_tag"
}

# VLESS: Reality/TCP, certificate TLS/TCP+WS, and no TLS/TCP+WS.
run_case vless-reality 2 vless reality tcp 1 1 '' ''
run_case vless-cert-tcp 2 vless cert tcp 1 1 '' ''
run_case vless-cert-ws 2 vless cert ws 1 1 '' '' '' '' 30000-50000 10326 /vless-ws
run_case vless-none-tcp 2 vless none tcp 1 1 '' ''
run_case vless-none-ws 2 vless none ws 1 1 '' '' '' '' 30000-50000 10326 /plain-ws

# AnyTLS: Reality and certificate TLS.
run_case anytls-reality 1 anytls reality tcp 1 1 '' ''
run_case anytls-cert 1 anytls cert tcp 1 1 '' ''

# Trojan: Reality/TCP and certificate TLS/TCP+WS.
run_case trojan-reality 4 trojan reality tcp 1 1 '' ''
run_case trojan-cert-tcp 4 trojan cert tcp 1 1 '' ''
run_case trojan-cert-ws 4 trojan cert ws 1 1 '' '' '' '' 30000-50000 10326 /trojan-ws

# Hysteria2: ordinary/hopping, obfuscation, and optional bandwidth limits.
run_case hy2-plain 3 hysteria2 cert tcp 1 1 '' ''
run_case hy2-obfs 3 hysteria2 cert tcp 1 2 '' ''
run_case hy2-hop 3 hysteria2 cert tcp 2 1 '' ''
run_case hy2-hop-obfs 3 hysteria2 cert tcp 2 2 '' ''
run_case hy2-bandwidth 3 hysteria2 cert tcp 1 1 100 200
run_case hy2-no-bandwidth 3 hysteria2 cert tcp 1 1 '' ''

# SOCKS and HTTP: unauthenticated and username/password modes.
run_case socks-open 5 socks none tcp 1 1 '' ''
run_case socks-auth 5 socks none tcp 1 1 '' '' socks-user
run_case http-open 6 http none tcp 1 1 '' ''
run_case http-auth 6 http none tcp 1 1 '' '' http-user

printf 'inbound build matrix passed.\n'
