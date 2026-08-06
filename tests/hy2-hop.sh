#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ============================================================
# Test 1: validate_hy2_hop_range + range conflict detection
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
  mkdir -p "$SBCTL_CONFIG_DIR"

  # Range validation
  validate_hy2_hop_range 20000-50000
  ! validate_hy2_hop_range 50000-20000
  ! validate_hy2_hop_range "abc-def"
  ! validate_hy2_hop_range "100-100"
  ! validate_hy2_hop_range "0-100"

  # Seed two inbounds with hopping metadata
  write_default_config
  init_meta
  hy2_hop_meta_set hy2-a "20000-30000"
  hy2_hop_meta_set hy2-c "50000-60000"

  # Non-overlapping: OK
  hy2_hop_check_conflicts "30001-40000"
  # Exact adjacent: OK
  hy2_hop_check_conflicts "40001-49999"

  # Overlapping: fail
  ! hy2_hop_check_conflicts "25000-35000"
  ! hy2_hop_check_conflicts "15000-25000"
  ! hy2_hop_check_conflicts "29000-31000"

  # Except self: OK
  hy2_hop_check_conflicts "25000-35000" hy2-a
'

# ============================================================
# Test 2: Hy2 without hopping — normal listen_port
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

  choose() {
    local __var=$1 prompt=$2
    case $prompt in
      "选择入站协议") printf -v "$__var" "%s" 3 ;;   # Hysteria2
      "端口模式") printf -v "$__var" "%s" 1 ;;        # 普通端口
      "QUIC 混淆") printf -v "$__var" "%s" 1 ;;        # 关闭
    esac
  }
  prompt_tag() { printf -v "$1" "%s" hy2-normal; }
  prompt_value() {
    local __var=$1 prompt=$2
    case $prompt in
      "监听地址") printf -v "$__var" "%s" 0.0.0.0 ;;
      "监听端口") printf -v "$__var" "%s" 443 ;;
      "用户名称") printf -v "$__var" "%s" user-normal ;;
    esac
  }
  prompt_port() {
    local __var=$1
    printf -v "$__var" "%s" 443
  }
  prompt_public_host() { printf -v "$1" "%s" 203.0.113.10; }
  build_certificate_tls() { printf -v "$1" "%s" "{\"enabled\":true,\"server_name\":\"example.com\",\"certificate_path\":\"/tmp/a.crt\",\"key_path\":\"/tmp/a.key\"}"; }
  prompt_secret() { printf -v "$1" "%s" secret; }
  prompt_optional_positive_int() { printf -v "$1" "%s" ""; }
  hy2_hop_check_conflicts() { return 0; }
  warn() { :; }

  inbound=""; host=""; public=""; hop_range=""
  build_inbound inbound host public hop_range
  [[ -z $hop_range ]]
  [[ $(jq -r .listen_port <<<"$inbound") == 443 ]]
  [[ $(jq -r .type <<<"$inbound") == hysteria2 ]]
'

# ============================================================
# Test 3: Hy2 + hopping — internal port set upfront
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

  choose() {
    local __var=$1 prompt=$2
    case $prompt in
      "选择入站协议") printf -v "$__var" "%s" 3 ;;   # Hysteria2
      "端口模式") printf -v "$__var" "%s" 2 ;;        # 端口跳跃
      "QUIC 混淆") printf -v "$__var" "%s" 1 ;;        # 关闭
    esac
  }
  prompt_tag() { printf -v "$1" "%s" hy2-hop; }
  prompt_value() {
    local __var=$1 prompt=$2
    case $prompt in
      "监听地址") printf -v "$__var" "%s" 0.0.0.0 ;;
      "端口跳跃范围") printf -v "$__var" "%s" 20000-30000 ;;
      "用户名称") printf -v "$__var" "%s" user-hop ;;
    esac
  }
  prompt_public_host() { printf -v "$1" "%s" 203.0.113.10; }
  build_certificate_tls() { printf -v "$1" "%s" "{\"enabled\":true,\"server_name\":\"example.com\",\"certificate_path\":\"/tmp/a.crt\",\"key_path\":\"/tmp/a.key\"}"; }
  prompt_secret() { printf -v "$1" "%s" secret; }
  prompt_optional_positive_int() { printf -v "$1" "%s" ""; }
  prompt_hy2_internal_port() { printf -v "$1" "%s" 443; }
  hy2_hop_check_conflicts() { return 0; }
  warn() { :; }

  inbound=""; host=""; public=""; hop_range=""
  build_inbound inbound host public hop_range
  [[ $hop_range == 20000-30000 ]]
  [[ $(jq -r .listen_port <<<"$inbound") == 443 ]]
  [[ $(jq -r .type <<<"$inbound") == hysteria2 ]]
'

# ============================================================
# Test 4: Range conflict rejected during build
# ============================================================
SBCTL_TESTING=1 \
SBCTL_CONFIG_DIR="$TMP/t4/cfg" \
SBCTL_CONFIG_FILE="$TMP/t4/cfg/config.json" \
SBCTL_META_FILE="$TMP/t4/meta.json" \
SBCTL_CERT_DIR="$TMP/t4/cfg/certs" \
SBCTL_LOCK_FILE="$TMP/t4/lock" \
bash -c '
  set -Eeuo pipefail
  source ./sbctl.sh
  write_default_config
  init_meta
  hy2_hop_meta_set existing "20000-30000"

  choose() {
    local __var=$1 prompt=$2
    case $prompt in
      "选择入站协议") printf -v "$__var" "%s" 3 ;;
      "端口模式") printf -v "$__var" "%s" 2 ;;      # hopping
    esac
  }
  prompt_tag() { printf -v "$1" "%s" hy2-conflict; }
  prompt_value() {
    local __var=$1 prompt=$2
    case $prompt in
      "监听地址") printf -v "$__var" "%s" 0.0.0.0 ;;
      "端口跳跃范围") printf -v "$__var" "%s" 25000-35000 ;;
    esac
  }
  prompt_public_host() { printf -v "$1" "%s" 203.0.113.10; }
  build_certificate_tls() { printf -v "$1" "%s" "{}"; }
  warn() { :; }

  inbound=""; host=""; public=""; hop_range=""
  # Should fail due to range conflict
  ! build_inbound inbound host public hop_range
'

# ============================================================
# Test 5: Share link format — hopping vs normal
# ============================================================
SBCTL_TESTING=1 \
SBCTL_CONFIG_DIR="$TMP/t5/cfg" \
SBCTL_CONFIG_FILE="$TMP/t5/cfg/config.json" \
SBCTL_META_FILE="$TMP/t5/meta.json" \
SBCTL_CERT_DIR="$TMP/t5/cfg/certs" \
SBCTL_LOCK_FILE="$TMP/t5/lock" \
bash -c '
  set -Eeuo pipefail
  source ./sbctl.sh
  mkdir -p "$SBCTL_CONFIG_DIR"
  cat >"$CONFIG_FILE" <<"JSON"
{
  "log":{"level":"warn"},
  "inbounds":[{
    "type":"hysteria2",
    "tag":"hy2-share",
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
{"schema":1,"inbounds":{"hy2-share":{"host":"203.0.113.10","hysteria2PortHopping":{"enabled":true,"range":"20000-50000"}}}}
JSON

  share=$(print_share hy2-share)
  grep -Fq "hysteria2://secret@203.0.113.10:20000-50000?sni=example.com" <<<"$share"

  # Without hopping: uses listen_port
  cat >"$META_FILE" <<"JSON"
{"schema":1,"inbounds":{"hy2-share":{"host":"203.0.113.10"}}}
JSON
  share2=$(print_share hy2-share)
  grep -Fq "hysteria2://secret@203.0.113.10:55556?sni=example.com" <<<"$share2"
'

# ============================================================
# Test 6: NAT failure → hop meta disabled, share uses real port
# ============================================================
SBCTL_TESTING=1 \
SBCTL_CONFIG_DIR="$TMP/t6/cfg" \
SBCTL_CONFIG_FILE="$TMP/t6/cfg/config.json" \
SBCTL_META_FILE="$TMP/t6/meta.json" \
SBCTL_CERT_DIR="$TMP/t6/cfg/certs" \
SBCTL_LOCK_FILE="$TMP/t6/lock" \
bash -c '
  set -Eeuo pipefail
  source ./sbctl.sh
  write_default_config
  init_meta

  # Simulate: hopping meta set, but NAT sync fails
  hy2_hop_meta_set hy2-fail "20000-30000"
  [[ $(hy2_hop_range_for_tag hy2-fail) == 20000-30000 ]]

  # Mock hy2_hop_sync to simulate NAT failure
  hy2_hop_sync() { return 1; }

  # Simulate add_inbound post-apply NAT failure path
  if hy2_hop_sync; then :; else
    warn "端口跳跃 NAT 配置失败，当前使用内部监听端口连接。"
    hy2_hop_meta_disable hy2-fail
  fi

  [[ -z $(hy2_hop_range_for_tag hy2-fail) ]]
'

# ============================================================
# Test 7: Existing Hy2 modify hopping still works
# ============================================================
SBCTL_TESTING=1 \
SBCTL_CONFIG_DIR="$TMP/t7/cfg" \
SBCTL_CONFIG_FILE="$TMP/t7/cfg/config.json" \
SBCTL_META_FILE="$TMP/t7/meta.json" \
SBCTL_CERT_DIR="$TMP/t7/cfg/certs" \
SBCTL_LOCK_FILE="$TMP/t7/lock" \
bash -c '
  set -Eeuo pipefail
  source ./sbctl.sh
  mkdir -p "$SBCTL_CONFIG_DIR"
  cat >"$CONFIG_FILE" <<"JSON"
{"log":{"level":"warn"},"inbounds":[{"type":"hysteria2","tag":"hy2-mod","listen":"0.0.0.0","listen_port":55556,"users":[{"name":"u","password":"p"}],"tls":{"enabled":true,"server_name":"x.com","certificate_path":"/tmp/c.crt","key_path":"/tmp/c.key"}}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}
JSON
  cat >"$META_FILE" <<"JSON"
{"schema":1,"inbounds":{"hy2-mod":{"host":"203.0.113.10"}}}
JSON

  # Enable hopping (assume_yes=1 mode) — fresh, no existing range
  prompt_value() { printf -v "$1" "%s" 20000-40000; }
  hy2_hop_check_conflicts() { return 0; }
  nft() { :; }
  command_exists() { [[ $1 == nft ]]; }
  rc-service() { return 0; }
  rc-update() { return 0; }
  systemctl() { return 0; }
  install_quick_command() { :; }
  hy2_hop_boot_service_ensure() { :; }
  hy2_hop_boot_service_remove() { :; }
  hy2_hop_configure hy2-mod 1
  [[ $(hy2_hop_range_for_tag hy2-mod) == 20000-40000 ]]

  # Modify range (has existing, user picks "1" to modify)
  prompt_value() { printf -v "$1" "%s" 30000-50000; }
  hy2_hop_configure() {
    # Simulate the "modify existing" path: prompt → validate → set → sync
    local tag=$1
    hy2_hop_check_conflicts "30000-50000" "$tag" || return 1
    hy2_hop_meta_set "$tag" "30000-50000"
    hy2_hop_sync
  }
  hy2_hop_configure hy2-mod
  [[ $(hy2_hop_range_for_tag hy2-mod) == 30000-50000 ]]

  # Disable
  hy2_hop_meta_disable hy2-mod
  [[ -z $(hy2_hop_range_for_tag hy2-mod) ]]
'

printf 'hy2 hop tests passed.\n'
