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
  hy2_hop_restore_all
  grep -Fq "add table inet sbctl_hy2_hop" "$NFT_LOG"
  grep -Fq "udp dport 20000-50000 redirect to :55556" "$NFT_LOG"
'

printf 'hy2 hop test passed.\n'
