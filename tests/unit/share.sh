#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export SBCTL_TESTING=1
export SBCTL_CONFIG_DIR="$TMP/config"
export SBCTL_CONFIG_FILE="$TMP/config/config.json"
export SBCTL_META_FILE="$TMP/meta.json"
export SBCTL_CERT_DIR="$TMP/config/certs"
export SBCTL_LOCK_FILE="$TMP/lock"
source ./sbctl.sh

mkdir -p "$CONFIG_DIR"
cat >"$CONFIG_FILE" <<'JSON'
{
  "log":{"level":"warn"},
  "inbounds":[
    {"type":"vless","tag":"vless-reality","listen":"0.0.0.0","listen_port":443,
      "users":[{"name":"reality-user","uuid":"11111111-1111-4111-8111-111111111111","flow":"xtls-rprx-vision"}],
      "tls":{"enabled":true,"server_name":"reality.example.com","reality":{"enabled":true,"handshake":{"server":"target.example.com","server_port":8443},"private_key":"reality-private","short_id":["ab12"]}}},
    {"type":"vless","tag":"vless-tls","listen":"0.0.0.0","listen_port":8443,
      "users":[{"name":"tls-user","uuid":"22222222-2222-4222-8222-222222222222","flow":""}],
      "tls":{"enabled":true,"server_name":"tls.example.com","certificate_path":"/tmp/c.crt","key_path":"/tmp/c.key"}},
    {"type":"vless","tag":"vless-tls-ws","listen":"0.0.0.0","listen_port":9443,
      "users":[{"name":"ws user","uuid":"33333333-3333-4333-8333-333333333333","flow":""}],
      "tls":{"enabled":true,"server_name":"tls-ws.example.com","certificate_path":"/tmp/c.crt","key_path":"/tmp/c.key"},
      "transport":{"type":"ws","path":"/vless ws","headers":{"Host":"ws.example.com"}}},
    {"type":"anytls","tag":"anytls-reality","listen":"0.0.0.0","listen_port":10443,
      "users":[{"name":"any-real","password":"any-real-pass"}],
      "tls":{"enabled":true,"server_name":"any.example.com","reality":{"enabled":true,"private_key":"reality-private","short_id":["ab12"]}}},
    {"type":"anytls","tag":"anytls-tls","listen":"0.0.0.0","listen_port":11443,
      "users":[{"name":"any-tls","password":"any tls pass"}],
      "tls":{"enabled":true,"server_name":"any-tls.example.com"}},
    {"type":"trojan","tag":"trojan-reality","listen":"0.0.0.0","listen_port":12443,
      "users":[{"name":"trojan-real","password":"trojan-real-pass"}],
      "tls":{"enabled":true,"server_name":"trojan.example.com","reality":{"enabled":true,"private_key":"reality-private","short_id":["ab12"]}}},
    {"type":"trojan","tag":"trojan-tls","listen":"0.0.0.0","listen_port":13443,
      "users":[{"name":"trojan tls","password":"trojan@pass"}],
      "tls":{"enabled":true,"server_name":"trojan-tls.example.com"}},
    {"type":"trojan","tag":"trojan-tls-ws","listen":"0.0.0.0","listen_port":14443,
      "users":[{"name":"trojan-ws","password":"trojan-ws-pass"}],
      "tls":{"enabled":true,"server_name":"trojan-ws.example.com"},
      "transport":{"type":"ws","path":"/trojan ws","headers":{"Host":"trojan-ws.example.com"}}},
    {"type":"hysteria2","tag":"hy2-plain","listen":"0.0.0.0","listen_port":15443,
      "users":[{"name":"hy2-user","password":"hy2@pass"}],
      "tls":{"enabled":true,"server_name":"hy2.example.com"}},
    {"type":"hysteria2","tag":"hy2-hop-obfs","listen":"0.0.0.0","listen_port":16443,
      "users":[{"name":"hy2-hop","password":"hy2-hop-pass"}],
      "tls":{"enabled":true,"server_name":"hy2-hop.example.com"},
      "obfs":{"type":"salamander","password":"obfs secret"}},
    {"type":"socks","tag":"socks-open","listen":"0.0.0.0","listen_port":17443,"users":[]},
    {"type":"socks","tag":"socks-auth","listen":"0.0.0.0","listen_port":18443,"users":[{"username":"user name","password":"p@ss"}]},
    {"type":"http","tag":"http-open","listen":"0.0.0.0","listen_port":19443,"users":[]},
    {"type":"http","tag":"http-auth","listen":"0.0.0.0","listen_port":20443,"users":[{"username":"http user","password":"http@pass"}]}
  ],
  "outbounds":[{"type":"direct","tag":"direct"}],
  "route":{"final":"direct"}
}
JSON

private_sha=$(printf '%s' reality-private | openssl dgst -sha256 -r | awk '{print $1}')
cat >"$META_FILE" <<JSON
{
  "schema":2,
  "inbounds":{
    "vless-reality":{"host":"reality.example.com","realityPublicKey":"PUB+/=","realityPrivateSHA256":"$private_sha"},
    "vless-tls":{"host":"tls.example.com"},
    "vless-tls-ws":{"host":"tls-ws.example.com"},
    "anytls-reality":{"host":"any.example.com","realityPublicKey":"PUB+/=","realityPrivateSHA256":"$private_sha"},
    "anytls-tls":{"host":"any-tls.example.com"},
    "trojan-reality":{"host":"trojan.example.com","realityPublicKey":"PUB+/=","realityPrivateSHA256":"$private_sha"},
    "trojan-tls":{"host":"trojan-tls.example.com"},
    "trojan-tls-ws":{"host":"trojan-ws.example.com"},
    "hy2-plain":{"host":"hy2.example.com"},
    "hy2-hop-obfs":{"host":"hy2-hop.example.com","hysteria2PortHopping":{"enabled":true,"range":"30000-50000"}},
    "socks-open":{"host":"socks.example.com"},
    "socks-auth":{"host":"socks.example.com"},
    "http-open":{"host":"http.example.com"},
    "http-auth":{"host":"http.example.com"}
  }
}
JSON

assert_contains() {
  local output=$1 expected=$2
  grep -Fq -- "$expected" <<<"$output" || {
    printf 'share assertion failed: missing %s\n%s\n' "$expected" "$output" >&2
    return 1
  }
}

output=$(print_share vless-reality)
assert_contains "$output" 'vless://11111111-1111-4111-8111-111111111111@reality.example.com:443?type=tcp&security=reality&sni=reality.example.com&fp=chrome&pbk=PUB%2B%2F%3D&sid=ab12&spx=%2F&flow=xtls-rprx-vision#vless-reality-reality-user'

output=$(print_share vless-tls)
assert_contains "$output" 'vless://22222222-2222-4222-8222-222222222222@tls.example.com:8443?type=tcp&security=tls&sni=tls.example.com#vless-tls-tls-user'

output=$(print_share vless-tls-ws)
assert_contains "$output" 'vless://33333333-3333-4333-8333-333333333333@tls-ws.example.com:9443?type=ws&security=tls&sni=tls-ws.example.com&host=ws.example.com&path=%2Fvless%20ws#vless-tls-ws-ws%20user'

output=$(print_share anytls-reality)
assert_contains "$output" '"server": "any.example.com"'
assert_contains "$output" '"server_port": 10443'
assert_contains "$output" '"public_key": "PUB+/="'
assert_contains "$output" '"short_id": "ab12"'

output=$(print_share anytls-tls)
assert_contains "$output" 'anytls://any%20tls%20pass@any-tls.example.com:11443/?sni=any-tls.example.com#anytls-tls-any-tls'

output=$(print_share trojan-reality)
assert_contains "$output" 'trojan://trojan-real-pass@trojan.example.com:12443?type=tcp&security=reality&sni=trojan.example.com&fp=chrome&pbk=PUB%2B%2F%3D&sid=ab12&spx=%2F#trojan-reality-trojan-real'

output=$(print_share trojan-tls)
assert_contains "$output" 'trojan://trojan%40pass@trojan-tls.example.com:13443?type=tcp&security=tls&sni=trojan-tls.example.com#trojan-tls-trojan%20tls'

output=$(print_share trojan-tls-ws)
assert_contains "$output" 'trojan://trojan-ws-pass@trojan-ws.example.com:14443?type=ws&security=tls&sni=trojan-ws.example.com&host=trojan-ws.example.com&path=%2Ftrojan%20ws#trojan-tls-ws-trojan-ws'

output=$(print_share hy2-plain)
assert_contains "$output" 'hysteria2://hy2%40pass@hy2.example.com:15443?sni=hy2.example.com#hy2-plain-hy2-user'

output=$(print_share hy2-hop-obfs)
assert_contains "$output" 'hysteria2://hy2-hop-pass@hy2-hop.example.com:30000-50000?sni=hy2-hop.example.com&obfs=salamander&obfs-password=obfs%20secret#hy2-hop-obfs-hy2-hop'

output=$(print_share socks-open)
assert_contains "$output" 'socks://socks.example.com:17443  无认证'

output=$(print_share socks-auth)
assert_contains "$output" 'socks://user%20name:p%40ss@socks.example.com:18443#socks-auth-user%20name'

output=$(print_share http-open)
assert_contains "$output" 'http://http.example.com:19443  无认证'

output=$(print_share http-auth)
assert_contains "$output" 'http://http%20user:http%40pass@http.example.com:20443#http-auth-http%20user'

printf 'share matrix passed.\n'
