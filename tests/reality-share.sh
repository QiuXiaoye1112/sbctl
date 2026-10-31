#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

SBCTL_CONFIG_DIR="$TMP/cfg" \
SBCTL_CONFIG_FILE="$TMP/cfg/config.json" \
SBCTL_META_FILE="$TMP/meta.json" \
SBCTL_CERT_DIR="$TMP/certs" \
SBCTL_LOCK_FILE="$TMP/lock" \
bash -c '
  set -Eeuo pipefail
  source ./sbctl.sh

  generate_reality_keys() {
    printf -v "$1" "%s" "private-test"
    printf -v "$2" "%s" "public-test"
  }
  random_hex() { printf 0123abcd; }

  tls=""; public=""
  build_reality_tls tls public <<EOF
example.com:8443

EOF
  jq -e ".reality.handshake.server==\"example.com\" and .reality.handshake.server_port==8443 and .server_name==\"example.com\"" <<<"$tls" >/dev/null
  [[ $public == public-test ]]

  mkdir -p "$CONFIG_DIR" "$CERT_DIR"
  cat >"$CONFIG_FILE" <<JSON
{
  "inbounds": [{
    "type": "anytls",
    "tag": "anytls-test",
    "listen": "0.0.0.0",
    "listen_port": 21312,
    "users": [{"name":"user-007b","password":"user-password"}],
    "tls": {
      "enabled": true,
      "server_name": "www.microsoft.com",
      "reality": {
        "enabled": true,
        "handshake": {"server":"www.microsoft.com","server_port":443},
        "private_key": "private-test",
        "short_id": ["651a1e7b06f38a97"]
      }
    }
  }],
  "outbounds": [{"type":"direct","tag":"direct"}],
  "route": {"final":"direct"}
}
JSON
  sha=$(printf %s private-test | openssl dgst -sha256 -r | awk "{print \$1}")
  cat >"$META_FILE" <<JSON
{"inbounds":{"anytls-test":{"host":"192.236.223.194","realityPublicKey":"YYoeEzXUPLu5wq2RwTQpfx9hpvGuuWTWF60hp4Eklkg","realityPrivateSHA256":"$sha"}}}
JSON

  output=$(print_share anytls-test)
  grep -Fq "anytls-test 分享信息" <<<"$output"
  grep -Fq "用户: user-007b" <<<"$output"
  grep -Fq "客户端 outbound JSON" <<<"$output"
  grep -Fq "YYoeEzXUPLu5wq2RwTQpfx9hpvGuuWTWF60hp4Eklkg" <<<"$output"
  grep -Fq -- "------------------------------------------------------------------------" <<<"$output"
'

printf 'reality/share test passed.\n'
