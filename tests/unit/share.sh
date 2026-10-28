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
      "users":[{"name":"tls-user","uuid":"22222222-2222-4222-8222-222222222222","flow":"xtls-rprx-vision"}],
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
assert_contains "$output" 'vless://22222222-2222-4222-8222-222222222222@tls.example.com:8443?type=tcp&security=tls&sni=tls.example.com&flow=xtls-rprx-vision#vless-tls-tls-user'

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
assert_contains "$output" 'socks5://socks.example.com:17443#socks-open'

output=$(print_share socks-auth)
assert_contains "$output" 'socks5://user%20name:p%40ss@socks.example.com:18443#socks-auth-user%20name'

output=$(print_share http-open)
assert_contains "$output" 'http://http.example.com:19443#http-open'

output=$(print_share http-auth)
assert_contains "$output" 'http://http%20user:http%40pass@http.example.com:20443#http-auth-http%20user'

subscription=$(print_subscription | base64 -d)
[[ $(printf '%s\n' "$subscription" | wc -l) == 3 ]]
[[ $(printf '%s\n' "$subscription" | grep -c '^vless://') == 3 ]]
assert_contains "$subscription" 'type=ws&security=tls'
subscription=$(print_subscription vless-tls-ws | base64 -d)
[[ $(printf '%s\n' "$subscription" | wc -l) == 1 ]]
assert_contains "$subscription" '33333333-3333-4333-8333-333333333333'
if print_subscription socks-open >/dev/null; then printf 'non-VLESS subscription must fail\n' >&2; exit 1; fi
if print_subscription missing >/dev/null; then printf 'unknown subscription must fail\n' >&2; exit 1; fi
jq '(.inbounds[] | select(.tag=="vless-tls-ws") | .users) = []' "$CONFIG_FILE" >"$CONFIG_FILE.tmp"
mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
if print_subscription vless-tls-ws >/dev/null; then printf 'empty subscription must fail\n' >&2; exit 1; fi
jq 'del(.inbounds["vless-reality"].realityPublicKey)' "$META_FILE" >"$META_FILE.tmp"
mv "$META_FILE.tmp" "$META_FILE"
if print_subscription >/dev/null; then printf 'subscription must fail without REALITY key\n' >&2; exit 1; fi
jq 'del(.inbounds["trojan-reality"].realityPublicKey, .inbounds["anytls-reality"].realityPublicKey)' "$META_FILE" >"$META_FILE.tmp"
mv "$META_FILE.tmp" "$META_FILE"
if print_share trojan-reality >/dev/null; then printf 'Trojan share must fail without REALITY key\n' >&2; exit 1; fi
if print_share anytls-reality >"$TMP/anytls-share"; then printf 'AnyTLS share must fail without REALITY key\n' >&2; exit 1; fi
if grep -q 'public_key' "$TMP/anytls-share"; then printf 'AnyTLS share emitted incomplete client configuration\n' >&2; exit 1; fi
if print_all_share >/dev/null; then printf 'bulk share must report failures\n' >&2; exit 1; fi

printf 'share matrix passed.\n'
