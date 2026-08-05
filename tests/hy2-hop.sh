#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

SBCTL_TESTING=1 \
SBCTL_CONFIG_DIR="$TMP/cfg" \
SBCTL_CONFIG_FILE="$TMP/cfg/config.json" \
SBCTL_META_FILE="$TMP/meta.json" \
SBCTL_CERT_DIR="$TMP/cfg/certs" \
SBCTL_LOCK_FILE="$TMP/lock" \
NFT_LOG="$TMP/nft.log" \
bash -c '
  set -Eeuo pipefail
  source ./sbctl.sh
  mkdir -p "$SBCTL_CONFIG_DIR"
  cat >"$CONFIG_FILE" <<"JSON"
{
  "log":{"level":"warn"},
  "inbounds":[{
    "type":"hysteria2",
    "tag":"hy2-test",
    "listen":"0.0.0.0",
    "listen_port":55556,
    "users":[{"name":"user-a","password":"secret"}],
    "tls":{"enabled":true,"server_name":"example.com","certificate_path":"/tmp/test.crt","key_path":"/tmp/test.key"}
  }],
  "outbounds":[{"type":"direct","tag":"direct"}],
  "route":{"final":"direct"}
}
JSON
  cat >"$META_FILE" <<"JSON"
{
  "schema":1,
  "inbounds":{
    "hy2-test":{
      "host":"203.0.113.10",
      "hysteria2PortHopping":{"enabled":true,"range":"20000-50000"}
    }
  }
}
JSON

  validate_hy2_hop_range 20000-50000
  ! validate_hy2_hop_range 50000-20000
  [[ $(hy2_hop_client_port_spec hy2-test 55556) == 20000-50000 ]]

  # Manual internal ports inside the hopping range must be rejected and reprompted.
  attempt=0
  warnings=""
  prompt_optional() {
    local __var=$1
    ((attempt+=1))
    if ((attempt == 1)); then printf -v "$__var" "%s" 30000; else printf -v "$__var" "%s" 60000; fi
  }
  port_in_use_os() { return 1; }
  warn() { warnings+="$*"$'"'"'\n'"'"'; }
  selected=""
  prompt_hy2_internal_port selected 20000-50000
  [[ $selected == 60000 ]]
  [[ $attempt == 2 ]]
  grep -Fq "内部监听端口不能位于跳跃端口范围 20000-50000 内。" <<<"$warnings"

  share=$(print_share hy2-test)
  grep -Fq "hysteria2://secret@203.0.113.10:20000-50000?sni=example.com" <<<"$share"

  nft() { printf "%s\n" "$*" >>"$NFT_LOG"; }
  command_exists() { [[ $1 == nft ]]; }
  hy2_hop_restore_all
  grep -Fq "add table inet sbctl_hy2_hop" "$NFT_LOG"
  grep -Fq "udp dport 20000-50000 redirect to :55556" "$NFT_LOG"
'

# Regression: build_inbound must return the selected hop range to its caller.
SBCTL_TESTING=1 \
SBCTL_CONFIG_DIR="$TMP/build/cfg" \
SBCTL_CONFIG_FILE="$TMP/build/cfg/config.json" \
SBCTL_META_FILE="$TMP/build/meta.json" \
SBCTL_CERT_DIR="$TMP/build/cfg/certs" \
SBCTL_LOCK_FILE="$TMP/build/lock" \
bash -c '
  set -Eeuo pipefail
  source ./sbctl.sh
  write_default_config
  choose() {
    local __var=$1 prompt=$2
    case $prompt in
      "选择入站协议") printf -v "$__var" "%s" 3 ;;
      "端口模式") printf -v "$__var" "%s" 2 ;;
      "QUIC 混淆") printf -v "$__var" "%s" 1 ;;
      *) echo "unexpected choose prompt: $prompt" >&2; return 1 ;;
    esac
  }
  prompt_tag() { printf -v "$1" "%s" hy2-created; }
  prompt_value() {
    local __var=$1 prompt=$2
    case $prompt in
      "监听地址") printf -v "$__var" "%s" 0.0.0.0 ;;
      "跳跃端口范围") printf -v "$__var" "%s" 20000-50000 ;;
      "用户名称") printf -v "$__var" "%s" user-test ;;
      *) echo "unexpected prompt_value: $prompt" >&2; return 1 ;;
    esac
  }
  prompt_hy2_internal_port() { printf -v "$1" "%s" 60000; }
  prompt_public_host() { printf -v "$1" "%s" 203.0.113.10; }
  build_certificate_tls() { printf -v "$1" "%s" '{"enabled":true,"server_name":"example.com","certificate_path":"/tmp/a.crt","key_path":"/tmp/a.key"}'; }
  prompt_secret() { printf -v "$1" "%s" secret; }
  prompt_optional_positive_int() { printf -v "$1" "%s" ""; }
  hy2_hop_check_conflicts() { return 0; }
  warn() { :; }

  inbound=""; host=""; public=""; hop_range=""
  build_inbound inbound host public hop_range
  [[ $hop_range == 20000-50000 ]]
  [[ $(jq -r .listen_port <<<"$inbound") == 60000 ]]
  [[ $host == 203.0.113.10 ]]
'

printf 'hy2 hop test passed.\n'
