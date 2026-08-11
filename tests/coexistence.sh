#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export SBCTL_TESTING=1
export SBCTL_CONFIG_DIR="$TMP/sing-box"
export SBCTL_CONFIG_FILE="$SBCTL_CONFIG_DIR/config.json"
export SBCTL_META_FILE="$TMP/sbctl-meta.json"
export SBCTL_CERT_DIR="$SBCTL_CONFIG_DIR/certs"
export SBCTL_LOCK_FILE="$TMP/sbctl.lock"
export SBCTL_BBR_CONFIG="$TMP/99-sbctl-bbr.conf"
export SBCTL_XRAYCTL_BBR_CONFIG="$TMP/99-xrayctl-bbr.conf"
export SBCTL_CERTBOT_VENV="$TMP/certbot-venv"
export SBCTL_CERTBOT_SHARED_LOCK="$TMP/certbot.lock"
export SBCTL_CERTBOT_SHARED_LOCK_WAIT=0

source ./sbctl.sh
write_default_config
ensure_dependencies() { :; }
port_in_use_os() { [[ $1 == 25001 ]]; }
! declare -F port_in_xrayctl_config >/dev/null

hy2_port_in_default_hop_range 30000
hy2_port_in_default_hop_range 50000
! hy2_port_in_default_hop_range 29999
! hy2_port_in_default_hop_range 50001

random_file="$TMP/random-values"
printf '%s\n' 4e20 4e1f >"$random_file"
random_hex() {
  local value
  IFS= read -r value <"$random_file"
  tail -n +2 "$random_file" >"$random_file.next"
  mv "$random_file.next" "$random_file"
  printf '%s' "$value"
}
[[ $(_random_port_avoiding_hops) == 29999 ]]

printf '%s\n' 4e20 4e1f >"$random_file"
internal_port=""
hy2_pick_internal_port internal_port 51000-52000
[[ $internal_port == 29999 ]]

prompt_values=(25001 25002)
prompt_index=0
prompt_value() {
  printf -v "$1" '%s' "${prompt_values[$prompt_index]}"
  ((prompt_index+=1)) || true
}
selected=""
prompt_port selected 25001
[[ $selected == 25002 ]]

hy2_hop_check_conflicts 24000-26000
hy2_hop_check_conflicts 26001-27000

touch "$XRAYCTL_BBR_CONFIG"
[[ $(bbr_manager) == xrayctl ]]
printf '# managed by sbctl\nnet.ipv4.tcp_congestion_control=bbr\n' >"$SBCTL_BBR_CONFIG"
[[ $(bbr_manager) == both ]]
external_bbr="$TMP/third-party-bbr.conf"
touch "$external_bbr"
bbr_remove_known_persistence
[[ ! -e $SBCTL_BBR_CONFIG && ! -e $XRAYCTL_BBR_CONFIG ]]
[[ -e $external_bbr ]]
! declare -f disable_bbr | grep -Fq '拒绝关闭'

mkdir -p "$CERTBOT_VENV/bin"
cat >"$CERTBOT_BIN" <<'SH'
#!/usr/bin/env bash
[[ ${CERTBOT_STUB_FAIL:-0} != 1 ]]
SH
chmod +x "$CERTBOT_BIN"
certbot_cmd certonly --cert-name example >/dev/null
[[ ! -e $CERTBOT_SHARED_LOCK ]]

mkdir "$CERTBOT_SHARED_LOCK"
printf '%s\n' "$$" >"$CERTBOT_SHARED_LOCK/pid"
printf 'xrayctl\n' >"$CERTBOT_SHARED_LOCK/tool"
! certbot_cmd certonly --cert-name busy >/dev/null 2>&1
rm -f "$CERTBOT_SHARED_LOCK/pid" "$CERTBOT_SHARED_LOCK/tool"
rmdir "$CERTBOT_SHARED_LOCK"

mkdir "$CERTBOT_SHARED_LOCK"
printf '99999999\n' >"$CERTBOT_SHARED_LOCK/pid"
printf 'xrayctl\n' >"$CERTBOT_SHARED_LOCK/tool"
certbot_cmd certonly --cert-name stale >/dev/null
[[ ! -e $CERTBOT_SHARED_LOCK ]]

! CERTBOT_STUB_FAIL=1 certbot_cmd certonly --cert-name failed >/dev/null 2>&1
[[ ! -e $CERTBOT_SHARED_LOCK ]]

printf 'sbctl/xrayctl coexistence tests passed.\n'
