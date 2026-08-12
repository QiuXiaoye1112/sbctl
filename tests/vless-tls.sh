#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

_mock_cert_tls() {
  build_certificate_tls() {
    printf -v "$1" "%s" "{\"enabled\":true,\"server_name\":\"${3-example.com}\",\"certificate_path\":\"/tmp/c.crt\",\"key_path\":\"/tmp/c.key\"}"
    [[ -z ${2-} ]] || printf -v "$2" "%s" "${3-example.com}"
  }
}

_mock_reality() {
  require_sing_box() { :; }
  SING_BOX_BIN() { printf "fake\n"; }
  generate_reality_keys() { printf -v "$1" "%s" fake-priv; printf -v "$2" "%s" fake-pub; }
  random_hex() { printf "abcd"; }
}

# ============================================================
# Test 1: VLESS + cert TLS
# ============================================================
SBCTL_TESTING=1 SBCTL_CONFIG_DIR="$TMP/t1/cfg" SBCTL_CONFIG_FILE="$TMP/t1/cfg/config.json" \
  SBCTL_META_FILE="$TMP/t1/meta.json" SBCTL_CERT_DIR="$TMP/t1/cfg/certs" SBCTL_LOCK_FILE="$TMP/t1/lock" \
bash -c '
  set -Eeuo pipefail; source ./sbctl.sh; write_default_config
  prompt_public_host_called=0; prompt_public_host() { prompt_public_host_called=1; }
  choose() {
    local __var=$1 prompt=$2
    case $prompt in
      "选择入站协议") printf -v "$__var" "%s" 2 ;; "选择 TLS 安全层") printf -v "$__var" "%s" 2 ;;
      "传输方式") printf -v "$__var" "%s" 1 ;;
    esac
  }
  prompt_tag() { printf -v "$1" "%s" vless-tls; }
  prompt_value() { case "$2" in "监听地址") printf -v "$1" "%s" 0.0.0.0 ;; "监听端口") printf -v "$1" "%s" 443 ;; "用户名称") printf -v "$1" "%s" user1 ;; esac; }
  prompt_port() { printf -v "$1" "%s" 443; }; prompt_secret() { :; }; generate_uuid() { printf "uuid-1"; }
  '"$(declare -f _mock_cert_tls)"'; _mock_cert_tls
  inbound=""; host=""; public=""; hop=""
  build_inbound inbound host public hop
  [[ $(jq -r .type <<<"$inbound") == vless ]]
  [[ $(jq -r .tls.server_name <<<"$inbound") == example.com ]]
  [[ $host == example.com ]]
  [[ $prompt_public_host_called == 0 ]]
'

# ============================================================
# Test 2: AnyTLS + cert TLS
# ============================================================
SBCTL_TESTING=1 SBCTL_CONFIG_DIR="$TMP/t2/cfg" SBCTL_CONFIG_FILE="$TMP/t2/cfg/config.json" \
  SBCTL_META_FILE="$TMP/t2/meta.json" SBCTL_CERT_DIR="$TMP/t2/cfg/certs" SBCTL_LOCK_FILE="$TMP/t2/lock" \
bash -c '
  set -Eeuo pipefail; source ./sbctl.sh; write_default_config
  prompt_public_host_called=0; prompt_public_host() { prompt_public_host_called=1; }
  choose() {
    local __var=$1 prompt=$2
    case $prompt in
      "选择入站协议") printf -v "$__var" "%s" 1 ;; "选择 TLS 安全层") printf -v "$__var" "%s" 2 ;;
    esac
  }
  prompt_tag() { printf -v "$1" "%s" anytls-cert; }
  prompt_value() { case "$2" in "监听地址") printf -v "$1" "%s" 0.0.0.0 ;; "监听端口") printf -v "$1" "%s" 8443 ;; "用户名称") printf -v "$1" "%s" user2 ;; esac; }
  prompt_port() { printf -v "$1" "%s" 8443; }; prompt_secret() { printf -v "$1" "%s" pass2; }
  '"$(declare -f _mock_cert_tls)"'; _mock_cert_tls
  inbound=""; host=""; public=""; hop=""
  build_inbound inbound host public hop
  [[ $(jq -r .type <<<"$inbound") == anytls ]]
  [[ $(jq -r .tls.server_name <<<"$inbound") == example.com ]]
  [[ $host == example.com ]]
  [[ $prompt_public_host_called == 0 ]]
'

# ============================================================
# Test 3: Trojan + cert TLS
# ============================================================
SBCTL_TESTING=1 SBCTL_CONFIG_DIR="$TMP/t3/cfg" SBCTL_CONFIG_FILE="$TMP/t3/cfg/config.json" \
  SBCTL_META_FILE="$TMP/t3/meta.json" SBCTL_CERT_DIR="$TMP/t3/cfg/certs" SBCTL_LOCK_FILE="$TMP/t3/lock" \
bash -c '
  set -Eeuo pipefail; source ./sbctl.sh; write_default_config
  prompt_public_host_called=0; prompt_public_host() { prompt_public_host_called=1; }
  choose() {
    local __var=$1 prompt=$2
    case $prompt in
      "选择入站协议") printf -v "$__var" "%s" 4 ;; "选择 TLS 安全层") printf -v "$__var" "%s" 2 ;;
      "传输方式") printf -v "$__var" "%s" 1 ;;
    esac
  }
  prompt_tag() { printf -v "$1" "%s" trojan-cert; }
  prompt_value() { case "$2" in "监听地址") printf -v "$1" "%s" 0.0.0.0 ;; "监听端口") printf -v "$1" "%s" 443 ;; "用户名称") printf -v "$1" "%s" user3 ;; esac; }
  prompt_port() { printf -v "$1" "%s" 443; }; prompt_secret() { printf -v "$1" "%s" pass3; }
  '"$(declare -f _mock_cert_tls)"'; _mock_cert_tls
  inbound=""; host=""; public=""; hop=""
  build_inbound inbound host public hop
  [[ $(jq -r .type <<<"$inbound") == trojan ]]
  [[ $(jq -r .tls.server_name <<<"$inbound") == example.com ]]
  [[ $host == example.com ]]
  [[ $prompt_public_host_called == 0 ]]
'

# ============================================================
# Test 4: Hysteria2
# ============================================================
SBCTL_TESTING=1 SBCTL_CONFIG_DIR="$TMP/t4/cfg" SBCTL_CONFIG_FILE="$TMP/t4/cfg/config.json" \
  SBCTL_META_FILE="$TMP/t4/meta.json" SBCTL_CERT_DIR="$TMP/t4/cfg/certs" SBCTL_LOCK_FILE="$TMP/t4/lock" \
bash -c '
  set -Eeuo pipefail; source ./sbctl.sh; write_default_config
  prompt_public_host_called=0; prompt_public_host() { prompt_public_host_called=1; }
  choose() {
    local __var=$1 prompt=$2
    case $prompt in
      "选择入站协议") printf -v "$__var" "%s" 3 ;;
      "端口模式") printf -v "$__var" "%s" 1 ;; "QUIC 混淆") printf -v "$__var" "%s" 1 ;;
    esac
  }
  prompt_tag() { printf -v "$1" "%s" hy2-cert; }
  prompt_value() { case "$2" in "监听地址") printf -v "$1" "%s" 0.0.0.0 ;; "监听端口") printf -v "$1" "%s" 443 ;; "用户名称") printf -v "$1" "%s" user4 ;; esac; }
  prompt_port() { printf -v "$1" "%s" 443; }; prompt_secret() { printf -v "$1" "%s" pass4; }
  prompt_optional_positive_int() { printf -v "$1" "%s" ""; }
  hy2_hop_check_conflicts() { return 0; }
  '"$(declare -f _mock_cert_tls)"'; _mock_cert_tls
  inbound=""; host=""; public=""; hop=""
  build_inbound inbound host public hop
  [[ $(jq -r .type <<<"$inbound") == hysteria2 ]]
  [[ $(jq -r .tls.server_name <<<"$inbound") == example.com ]]
  [[ $host == example.com ]]
  [[ $prompt_public_host_called == 0 ]]
'

# ============================================================
# Test 5: VLESS + REALITY (regression)
# ============================================================
SBCTL_TESTING=1 SBCTL_CONFIG_DIR="$TMP/t5/cfg" SBCTL_CONFIG_FILE="$TMP/t5/cfg/config.json" \
  SBCTL_META_FILE="$TMP/t5/meta.json" SBCTL_CERT_DIR="$TMP/t5/cfg/certs" SBCTL_LOCK_FILE="$TMP/t5/lock" \
bash -c '
  set -Eeuo pipefail; source ./sbctl.sh; write_default_config
  prompt_public_host_called=0; prompt_public_host() { prompt_public_host_called=1; printf -v "$1" "%s" 1.2.3.4; }
  choose() {
    local __var=$1 prompt=$2
    case $prompt in
      "选择入站协议") printf -v "$__var" "%s" 2 ;; "选择 TLS 安全层") printf -v "$__var" "%s" 1 ;;
    esac
  }
  prompt_tag() { printf -v "$1" "%s" vless-real; }
  prompt_value() {
    case "$2" in
      "监听地址") printf -v "$1" "%s" 0.0.0.0 ;; "监听端口") printf -v "$1" "%s" 443 ;;
      "用户名称") printf -v "$1" "%s" user5 ;;
      "REALITY 目标") printf -v "$1" "%s" www.microsoft.com:443 ;;
      "REALITY serverName/SNI") printf -v "$1" "%s" www.microsoft.com ;;
    esac
  }
  prompt_port() { printf -v "$1" "%s" 443; }; prompt_secret() { :; }; generate_uuid() { printf "uuid-5"; }
  '"$(declare -f _mock_reality)"'; _mock_reality
  inbound=""; host=""; public=""; hop=""
  build_inbound inbound host public hop
  [[ $(jq -r .type <<<"$inbound") == vless ]]
  [[ $(jq -r .tls.server_name <<<"$inbound") == www.microsoft.com ]]
  [[ $(jq -r .tls.reality.enabled <<<"$inbound") == true ]]
  [[ $host == 1.2.3.4 ]]
  [[ $prompt_public_host_called == 1 ]]
'

# ============================================================
# Test 6: AnyTLS + REALITY (regression)
# ============================================================
SBCTL_TESTING=1 SBCTL_CONFIG_DIR="$TMP/t6/cfg" SBCTL_CONFIG_FILE="$TMP/t6/cfg/config.json" \
  SBCTL_META_FILE="$TMP/t6/meta.json" SBCTL_CERT_DIR="$TMP/t6/cfg/certs" SBCTL_LOCK_FILE="$TMP/t6/lock" \
bash -c '
  set -Eeuo pipefail; source ./sbctl.sh; write_default_config
  prompt_public_host_called=0; prompt_public_host() { prompt_public_host_called=1; printf -v "$1" "%s" 5.6.7.8; }
  choose() {
    local __var=$1 prompt=$2
    case $prompt in
      "选择入站协议") printf -v "$__var" "%s" 1 ;; "选择 TLS 安全层") printf -v "$__var" "%s" 1 ;;
    esac
  }
  prompt_tag() { printf -v "$1" "%s" anytls-real; }
  prompt_value() {
    case "$2" in
      "监听地址") printf -v "$1" "%s" 0.0.0.0 ;; "监听端口") printf -v "$1" "%s" 443 ;;
      "用户名称") printf -v "$1" "%s" user6 ;;
      "REALITY 目标") printf -v "$1" "%s" www.microsoft.com:443 ;;
      "REALITY serverName/SNI") printf -v "$1" "%s" www.microsoft.com ;;
    esac
  }
  prompt_port() { printf -v "$1" "%s" 443; }; prompt_secret() { printf -v "$1" "%s" pass6; }
  '"$(declare -f _mock_reality)"'; _mock_reality
  inbound=""; host=""; public=""; hop=""
  build_inbound inbound host public hop
  [[ $(jq -r .type <<<"$inbound") == anytls ]]
  [[ $(jq -r .tls.server_name <<<"$inbound") == www.microsoft.com ]]
  [[ $(jq -r .tls.reality.enabled <<<"$inbound") == true ]]
  [[ $host == 5.6.7.8 ]]
  [[ $prompt_public_host_called == 1 ]]
'

# ============================================================
# Test 7: Hy2 + hopping → cert host + range
# ============================================================
SBCTL_TESTING=1 SBCTL_CONFIG_DIR="$TMP/t7/cfg" SBCTL_CONFIG_FILE="$TMP/t7/cfg/config.json" \
  SBCTL_META_FILE="$TMP/t7/meta.json" SBCTL_CERT_DIR="$TMP/t7/cfg/certs" SBCTL_LOCK_FILE="$TMP/t7/lock" \
bash -c '
  set -Eeuo pipefail; source ./sbctl.sh; write_default_config
  prompt_public_host_called=0; prompt_public_host() { prompt_public_host_called=1; }
  choose() {
    local __var=$1 prompt=$2
    case $prompt in
      "选择入站协议") printf -v "$__var" "%s" 3 ;;
      "端口模式") printf -v "$__var" "%s" 2 ;; "QUIC 混淆") printf -v "$__var" "%s" 1 ;;
    esac
  }
  prompt_tag() { printf -v "$1" "%s" hy2-hop; }
  prompt_value() {
    case "$2" in
      "监听地址") printf -v "$1" "%s" 0.0.0.0 ;;
      "端口跳跃范围") printf -v "$1" "%s" 30000-50000 ;;
      "用户名称") printf -v "$1" "%s" user7 ;;
    esac
  }
  prompt_hy2_internal_port() { printf -v "$1" "%s" 10326; }
  prompt_secret() { printf -v "$1" "%s" pass7; }
  prompt_optional_positive_int() { printf -v "$1" "%s" ""; }
  hy2_hop_check_conflicts() { return 0; }
  '"$(declare -f _mock_cert_tls)"'; _mock_cert_tls
  inbound=""; host=""; public=""; hop=""
  build_inbound inbound host public hop
  [[ $(jq -r .type <<<"$inbound") == hysteria2 ]]
  [[ $(jq -r .listen_port <<<"$inbound") == 10326 ]]
  [[ $(jq -r .tls.server_name <<<"$inbound") == example.com ]]
  [[ $host == example.com ]]
  [[ $hop == 30000-50000 ]]
  [[ $prompt_public_host_called == 0 ]]
'

# ============================================================
# Test 8: modifying to cert TLS updates the client host to the certificate SNI
# ============================================================
SBCTL_TESTING=1 SBCTL_CONFIG_DIR="$TMP/t8/cfg" SBCTL_CONFIG_FILE="$TMP/t8/cfg/config.json" \
  SBCTL_META_FILE="$TMP/t8/meta.json" SBCTL_CERT_DIR="$TMP/t8/cfg/certs" SBCTL_LOCK_FILE="$TMP/t8/lock" \
bash -c '
  set -Eeuo pipefail; source ./sbctl.sh; write_default_config
  jq '\''.inbounds += [{type:"vless",tag:"vless-existing",listen:"0.0.0.0",listen_port:443,users:[{name:"u",uuid:"00000000-0000-0000-0000-000000000001"}],tls:{enabled:true,server_name:"old.example.com"}}]'\'' "$CONFIG_FILE" >"$CONFIG_FILE.tmp"
  mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  ensure_dependencies() { :; }; require_supported_core() { :; }
  choose() { printf -v "$1" "%s" 2; }
  build_certificate_tls() {
    printf -v "$1" "%s" "{\"enabled\":true,\"server_name\":\"cert.example.com\",\"certificate_path\":\"/tmp/c.crt\",\"key_path\":\"/tmp/c.key\"}"
    printf -v "$2" "%s" cert.example.com
  }
  public_host_for_tag() { printf "%s" old.example.com; }
  build_inbound_meta_candidate() { seen_host=$2; printf "{}" >"$5"; }
  apply_candidate_with_meta() { :; }
  seen_host=""
  modify_inbound_security vless-existing
  [[ $seen_host == cert.example.com ]]
'

echo "cert TLS host tests passed."
