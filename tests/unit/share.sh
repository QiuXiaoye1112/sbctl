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
    {"type":"anytls","tag":"anytls-reality","listen":"0.0.0.0","listen_port":10443,
      "users":[{"name":"any-real","password":"any-real-pass"}],
      "tls":{"enabled":true,"server_name":"any.example.com","reality":{"enabled":true,"private_key":"reality-private","short_id":["ab12"]}}},
    {"type":"anytls","tag":"anytls-tls","listen":"0.0.0.0","listen_port":11443,
      "users":[{"name":"any-tls","password":"any tls pass"}],
      "tls":{"enabled":true,"server_name":"any-tls.example.com"}},
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
    "anytls-reality":{"host":"any.example.com","realityPublicKey":"PUB+/=","realityPrivateSHA256":"$private_sha"},
    "anytls-tls":{"host":"any-tls.example.com"},
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

output=$(print_share anytls-reality)
assert_contains "$output" '"server": "any.example.com"'
assert_contains "$output" '"server_port": 10443'
assert_contains "$output" '"public_key": "PUB+/="'
assert_contains "$output" '"short_id": "ab12"'

output=$(print_share anytls-tls)
assert_contains "$output" 'anytls://any%20tls%20pass@any-tls.example.com:11443/?sni=any-tls.example.com#anytls-tls-any-tls'

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
[[ $(printf '%s\n' "$subscription" | wc -l) == 7 ]]
[[ $(printf '%s\n' "$subscription" | grep -c '^hysteria2://') == 2 ]]
[[ $(printf '%s\n' "$subscription" | grep -c '^anytls://') == 1 ]]
subscription=$(print_subscription hy2-plain | base64 -d)
[[ $(printf '%s\n' "$subscription" | wc -l) == 1 ]]
assert_contains "$subscription" 'hysteria2://hy2%40pass@hy2.example.com:15443?sni=hy2.example.com#hy2-plain-hy2-user'
if print_subscription missing >/dev/null; then printf 'unknown subscription must fail\n' >&2; exit 1; fi
jq 'del(.inbounds["anytls-reality"].realityPublicKey)' "$META_FILE" >"$META_FILE.tmp"
mv "$META_FILE.tmp" "$META_FILE"
if print_share anytls-reality >"$TMP/anytls-share"; then printf 'AnyTLS share must fail without REALITY key\n' >&2; exit 1; fi
if grep -q 'public_key' "$TMP/anytls-share"; then printf 'AnyTLS share emitted incomplete client configuration\n' >&2; exit 1; fi
if print_all_share >/dev/null; then printf 'bulk share must report failures\n' >&2; exit 1; fi

printf 'share matrix passed.\n'
