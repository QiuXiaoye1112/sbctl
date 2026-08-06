#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ============================================================
# Test 1: VLESS + cert TLS → client_host auto from certificate
# ============================================================
SBCTL_TESTING=1 \
SBCTL_CONFIG_DIR="$TMP/t1/cfg" \
SBCTL_CONFIG_FILE="$TMP/t1/cfg/config.json" \
SBCTL_META_FILE="$TMP/t1/meta.json" \
SBCTL_CERT_DIR="$TMP/t1/cfg/certs" \
SBCTL_LOCK_FILE="$TMP/t1/lock" \
bash -c '
  set -Eeuo pipefail
  source ./sbctl.sh
  write_default_config

  prompt_public_host_called=0
  prompt_public_host() { prompt_public_host_called=1; }

  choose() {
    local __var=$1 prompt=$2
    case $prompt in
      "选择入站协议") printf -v "$__var" "%s" 2 ;;    # VLESS
      "选择 TLS 安全层") printf -v "$__var" "%s" 2 ;;  # 证书 TLS
    esac
  }
  prompt_tag() { printf -v "$1" "%s" vless-tls; }
  prompt_value() {
    local __var=$1 prompt=$2
    case $prompt in
      "监听地址") printf -v "$__var" "%s" 0.0.0.0 ;;
      "监听端口") printf -v "$__var" "%s" 443 ;;
      "用户名称") printf -v "$__var" "%s" user-test ;;
    esac
  }
  prompt_port() { printf -v "$1" "%s" 443; }
  build_certificate_tls() { printf -v "$1" "%s" "{\"enabled\":true,\"server_name\":\"vmiss.example.com\",\"certificate_path\":\"/tmp/c.crt\",\"key_path\":\"/tmp/c.key\"}"; printf -v "$2" "%s" vmiss.example.com; }
  prompt_secret() { :; }
  generate_uuid() { printf "test-uuid-1234"; }

  inbound=""; host=""; public=""; hop=""
  build_inbound inbound host public hop
  [[ $(jq -r .type <<<"$inbound") == vless ]]
  [[ $(jq -r .tls.server_name <<<"$inbound") == vmiss.example.com ]]
  [[ $host == vmiss.example.com ]]
  [[ $prompt_public_host_called == 0 ]]
'

# ============================================================
# Test 2: VLESS + REALITY → client_host still prompted separately
# ============================================================
SBCTL_TESTING=1 \
SBCTL_CONFIG_DIR="$TMP/t2/cfg" \
SBCTL_CONFIG_FILE="$TMP/t2/cfg/config.json" \
SBCTL_META_FILE="$TMP/t2/meta.json" \
SBCTL_CERT_DIR="$TMP/t2/cfg/certs" \
SBCTL_LOCK_FILE="$TMP/t2/lock" \
bash -c '
  set -Eeuo pipefail
  source ./sbctl.sh
  write_default_config

  prompt_public_host_called=0
  prompt_public_host() { prompt_public_host_called=1; printf -v "$1" "%s" 1.2.3.4; }

  choose() {
    local __var=$1 prompt=$2
    case $prompt in
      "选择入站协议") printf -v "$__var" "%s" 2 ;;    # VLESS
      "选择 TLS 安全层") printf -v "$__var" "%s" 1 ;;  # REALITY
    esac
  }
  prompt_tag() { printf -v "$1" "%s" vless-reality; }
  prompt_value() {
    local __var=$1 prompt=$2
    case $prompt in
      "监听地址") printf -v "$__var" "%s" 0.0.0.0 ;;
      "监听端口") printf -v "$__var" "%s" 443 ;;
      "用户名称") printf -v "$__var" "%s" user-test ;;
      "REALITY 目标") printf -v "$__var" "%s" www.microsoft.com:443 ;;
      "REALITY serverName/SNI") printf -v "$__var" "%s" www.microsoft.com ;;
    esac
  }
  prompt_port() { printf -v "$1" "%s" 443; }
  require_sing_box() { :; }
  SING_BOX_BIN() { printf "fake\n"; }
  generate_reality_keys() { printf -v "$1" "%s" fake-priv; printf -v "$2" "%s" fake-pub; }
  prompt_secret() { :; }
  generate_uuid() { printf "test-uuid-456"; }
  random_hex() { printf "abcd"; }

  inbound=""; host=""; public=""; hop=""
  build_inbound inbound host public hop
  [[ $(jq -r .type <<<"$inbound") == vless ]]
  [[ $(jq -r .tls.server_name <<<"$inbound") == www.microsoft.com ]]
  [[ $(jq -r .tls.reality.enabled <<<"$inbound") == true ]]
  [[ $host == 1.2.3.4 ]]
  [[ $prompt_public_host_called == 1 ]]
'

# ============================================================
# Test 3: AnyTLS still uses prompt_public_host + separate cert
# ============================================================
SBCTL_TESTING=1 \
SBCTL_CONFIG_DIR="$TMP/t3/cfg" \
SBCTL_CONFIG_FILE="$TMP/t3/cfg/config.json" \
SBCTL_META_FILE="$TMP/t3/meta.json" \
SBCTL_CERT_DIR="$TMP/t3/cfg/certs" \
SBCTL_LOCK_FILE="$TMP/t3/lock" \
bash -c '
  set -Eeuo pipefail
  source ./sbctl.sh
  write_default_config

  prompt_public_host_called=0
  prompt_public_host() { prompt_public_host_called=1; printf -v "$1" "%s" 5.6.7.8; }

  choose() {
    local __var=$1 prompt=$2
    case $prompt in
      "选择入站协议") printf -v "$__var" "%s" 1 ;;    # AnyTLS
      "选择 TLS 安全层") printf -v "$__var" "%s" 2 ;;  # 证书 TLS
    esac
  }
  prompt_tag() { printf -v "$1" "%s" anytls-cert; }
  prompt_value() {
    local __var=$1 prompt=$2
    case $prompt in
      "监听地址") printf -v "$__var" "%s" 0.0.0.0 ;;
      "监听端口") printf -v "$__var" "%s" 443 ;;
      "用户名称") printf -v "$__var" "%s" user-test ;;
    esac
  }
  prompt_port() { printf -v "$1" "%s" 443; }
  build_certificate_tls() { printf -v "$1" "%s" "{\"enabled\":true,\"server_name\":\"cert.example.com\",\"certificate_path\":\"/tmp/c.crt\",\"key_path\":\"/tmp/c.key\"}"; }
  prompt_secret() { printf -v "$1" "%s" secret; }

  inbound=""; host=""; public=""; hop=""
  build_inbound inbound host public hop
  [[ $(jq -r .type <<<"$inbound") == anytls ]]
  [[ $(jq -r .tls.server_name <<<"$inbound") == cert.example.com ]]
  [[ $host == 5.6.7.8 ]]
  [[ $prompt_public_host_called == 1 ]]
'

echo "vless cert TLS tests passed."
