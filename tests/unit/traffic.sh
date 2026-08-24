#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

SBCTL_TESTING=1 \
SBCTL_CONFIG_DIR="$TMP/cfg" \
SBCTL_CONFIG_FILE="$TMP/cfg/config.json" \
SBCTL_META_FILE="$TMP/meta.json" \
SBCTL_TRAFFIC_FILE="$TMP/traffic.json" \
SBCTL_CERT_DIR="$TMP/cfg/certs" \
SBCTL_BACKUP_DIR="$TMP/backups" \
SBCTL_LOCK_FILE="$TMP/lock" \
bash <<'BASH'
set -Eeuo pipefail
source ./sbctl.sh

write_default_config
candidate=$(temp_file)
jq '.inbounds=[
  {"type":"vless","tag":"vless","listen":"0.0.0.0","listen_port":17225,"users":[]},
  {"type":"socks","tag":"socks","listen":"0.0.0.0","listen_port":5000,"users":[]},
  {"type":"hysteria2","tag":"hy2","listen":"0.0.0.0","listen_port":24443,"users":[]}
]' "$CONFIG_FILE" >"$candidate"
mv -f "$candidate" "$CONFIG_FILE"

# Calendar-month retention clamps missing dates at month end.
[[ $(traffic_months_ago 2026-08-24 3) == 2026-05-24 ]]
[[ $(traffic_months_ago 2024-05-31 3) == 2024-02-29 ]]
[[ $(traffic_months_ago 2025-05-31 3) == 2025-02-28 ]]
[[ $(traffic_limit_next_timestamp '2026-08-07 18:00:00' 7 '18:00:00') == '2026-09-07 18:00:00' ]]
[[ $(traffic_limit_next_timestamp '2026-01-31 18:00:00' 31 '18:00:00') == '2026-02-28 18:00:00' ]]
[[ $(traffic_limit_next_timestamp '2026-02-28 18:00:00' 31 '18:00:00') == '2026-03-31 18:00:00' ]]
traffic_validate_date 2024-02-29
! traffic_validate_date 2025-02-29
! traffic_validate_date 2026-13-01
traffic_validate_timestamp '2026-08-07 18:00:00'
! traffic_validate_timestamp '2026-08-07 24:00:00'

SBCTL_TRAFFIC_TODAY=2026-08-24
traffic_validate_range 2026-05-24 2026-08-24
traffic_validate_range 2026-08-24 2026-08-24
! traffic_validate_range 2026-05-23 2026-08-24
! traffic_validate_range 2026-08-20 2026-08-19
! traffic_validate_range 2026-08-20 2026-08-25
range_start=old; range_end=old
traffic_prompt_range range_start range_end <<< $'\n\n'
[[ $range_start == 2026-05-24 && $range_end == 2026-08-24 ]]

# Existing 0.5 traffic files gain the quota switch in the disabled state.
printf '%s\n' '{"schema":1,"enabled":false,"backend":"","lastCollectedAt":"","inbounds":{}}' >"$TRAFFIC_FILE"
traffic_init_file
jq -e '.limitsEnabled==false' "$TRAFFIC_FILE" >/dev/null

# Collection adds one sample to the current daily bucket and resets rules only
# after the file was committed. Backend functions are mocked at this boundary.
traffic_set_enabled true
MOCK_COUNTERS=$'vless\t1073741824\nsocks\t2048\nhy2\t4096'
RESTORE_CALLS=0
traffic_read_counters() { printf '%s\n' "$MOCK_COUNTERS"; }
traffic_rules_restore() { RESTORE_CALLS=$((RESTORE_CALLS + 1)); }
traffic_collect
[[ $RESTORE_CALLS == 1 ]]
jq -e '
  .enabled==true and
  .limitsEnabled==false and
  .inbounds.vless.daily["2026-08-24"]==1073741824 and
  .inbounds.socks.daily["2026-08-24"]==2048 and
  .inbounds.hy2.daily["2026-08-24"]==4096
' "$TRAFFIC_FILE" >/dev/null
last=$(jq -r .lastCollectedAt "$TRAFFIC_FILE")
traffic_sync_inventory
[[ $(jq -r .lastCollectedAt "$TRAFFIC_FILE") == "$last" ]]

output=$(traffic_show 2026-05-24 2026-08-24)
grep -Fq '统计范围：2026-05-24 ～ 2026-08-24' <<<"$output"
grep -Fq '1.00 GB' <<<"$output"
grep -Fq '全部入站：1.00 GB' <<<"$output"

# Entries older than the three-calendar-month cutoff are removed, while the
# cutoff day and current day remain queryable.
tmp=$(temp_file)
jq '.inbounds.vless.daily += {"2026-05-23":100,"2026-05-24":200}' "$TRAFFIC_FILE" >"$tmp"
install -m 600 "$tmp" "$TRAFFIC_FILE"; rm -f "$tmp"
traffic_sync_inventory
jq -e '
  (.inbounds.vless.daily["2026-05-23"] == null) and
  .inbounds.vless.daily["2026-05-24"]==200
' "$TRAFFIC_FILE" >/dev/null

# A rename preserves and merges daily history under the new inbound tag.
tmp=$(temp_file)
jq '(.inbounds[]|select(.tag=="vless")|.tag)="vless-new"' "$CONFIG_FILE" >"$tmp"
mv -f "$tmp" "$CONFIG_FILE"
traffic_sync_inventory
traffic_rename_records vless vless-new
jq -e '
  (.inbounds.vless == null) and
  .inbounds["vless-new"].daily["2026-08-24"]==1073741824 and
  .inbounds["vless-new"].daily["2026-05-24"]==200
' "$TRAFFIC_FILE" >/dev/null

# Deleted inbounds keep their retained history and are marked for display.
tmp=$(temp_file)
jq '.inbounds |= map(select(.tag!="socks"))' "$CONFIG_FILE" >"$tmp"
mv -f "$tmp" "$CONFIG_FILE"
traffic_sync_inventory
jq -e '.inbounds.socks.deleted==true and .inbounds.socks.daily["2026-08-24"]==2048' "$TRAFFIC_FILE" >/dev/null

[[ $(traffic_format_bytes 0) == '0 B' ]]
[[ $(traffic_format_bytes 1024) == '1.00 KB' ]]

# Backups include the retained traffic file and restore it atomically with the
# rest of sbctl state.
traffic_set_enabled false
archive="${TRAFFIC_FILE%/*}/traffic-backup.tar.gz"
backup_all "$archive" >/dev/null
tmp=$(temp_file)
jq '.inbounds["vless-new"].daily["2026-08-24"]=1' "$TRAFFIC_FILE" >"$tmp"
install -m 600 "$tmp" "$TRAFFIC_FILE"; rm -f "$tmp"
confirm() { return 0; }
restart_service_checked() { return 0; }
hy2_hop_sync() { return 0; }
restore_backup "$archive" >/dev/null
jq -e '.inbounds["vless-new"].daily["2026-08-24"]==1073741824' "$TRAFFIC_FILE" >/dev/null
BASH

# Monthly limits start at the exact creation time, retain that anchor when the
# quota changes, block only at the quota, and roll over at the next timestamp.
SBCTL_TESTING=1 \
SBCTL_TRAFFIC_BACKEND=nft \
SBCTL_TRAFFIC_TODAY=2026-08-07 \
SBCTL_TRAFFIC_NOW='2026-08-07 18:00:00' \
SBCTL_CONFIG_DIR="$TMP/limits/cfg" \
SBCTL_CONFIG_FILE="$TMP/limits/cfg/config.json" \
SBCTL_META_FILE="$TMP/limits/meta.json" \
SBCTL_TRAFFIC_FILE="$TMP/limits/traffic.json" \
SBCTL_CERT_DIR="$TMP/limits/cfg/certs" \
SBCTL_LOCK_FILE="$TMP/limits/lock" \
bash <<'BASH_LIMITS'
set -Eeuo pipefail
source ./sbctl.sh
write_default_config
tmp=$(temp_file)
jq '.inbounds=[{"type":"vless","tag":"vless","listen":"0.0.0.0","listen_port":17225,"users":[]}]' "$CONFIG_FILE" >"$tmp"
mv -f "$tmp" "$CONFIG_FILE"
traffic_set_backend nft
traffic_set_enabled true
traffic_sync_inventory
! traffic_limits_are_enabled
MOCK_COUNTERS=""
traffic_read_counters() { printf '%s' "$MOCK_COUNTERS"; }
traffic_rules_restore() { :; }
traffic_limits_enable >/dev/null
traffic_limits_are_enabled
traffic_limits_disable >/dev/null
! traffic_limits_are_enabled
traffic_limits_enable >/dev/null
traffic_limit_set vless 1 >/dev/null
jq -e '
  .limitsEnabled==true and
  .inbounds.vless.limit.quotaBytes==1073741824 and
  .inbounds.vless.limit.usedBytes==0 and
  .inbounds.vless.limit.cycleStart=="2026-08-07 18:00:00" and
  .inbounds.vless.limit.cycleEnd=="2026-09-07 18:00:00"
' "$TRAFFIC_FILE" >/dev/null
output=$(traffic_limits_show)
grep -Fq '功能状态：已启用' <<<"$output"
grep -Fq '当前周期：2026-08-07 18:00:00 ～ 2026-09-07 18:00:00' <<<"$output"

MOCK_COUNTERS=$'vless\t536870912\n'
traffic_collect
! traffic_limit_is_blocked vless
MOCK_COUNTERS=$'vless\t536870912\n'
traffic_collect
traffic_limit_is_blocked vless
grep -Fq '已禁用' <<<"$(traffic_limits_show)"
MOCK_COUNTERS=""
traffic_limits_disable >/dev/null
! traffic_limits_are_enabled
! traffic_limit_is_blocked vless
jq -e '.inbounds.vless.limit.usedBytes==1073741824' "$TRAFFIC_FILE" >/dev/null
traffic_limits_enable >/dev/null
traffic_limit_is_blocked vless
! traffic_disable 2>/dev/null
traffic_is_enabled

# Changing only the quota must not restart the billing cycle.
SBCTL_TRAFFIC_NOW='2026-08-20 12:34:56'
SBCTL_TRAFFIC_TODAY=2026-08-20
MOCK_COUNTERS=""
traffic_limit_set vless 2 >/dev/null
jq -e '
  .inbounds.vless.limit.quotaBytes==2147483648 and
  .inbounds.vless.limit.usedBytes==1073741824 and
  .inbounds.vless.limit.cycleStart=="2026-08-07 18:00:00" and
  .inbounds.vless.limit.cycleEnd=="2026-09-07 18:00:00"
' "$TRAFFIC_FILE" >/dev/null

SBCTL_TRAFFIC_NOW='2026-09-07 17:59:59'
SBCTL_TRAFFIC_TODAY=2026-09-07
traffic_sync_inventory
jq -e '.inbounds.vless.limit.usedBytes==1073741824' "$TRAFFIC_FILE" >/dev/null
SBCTL_TRAFFIC_NOW='2026-09-07 18:00:00'
traffic_sync_inventory
jq -e '
  .inbounds.vless.limit.usedBytes==0 and
  .inbounds.vless.limit.cycleStart=="2026-09-07 18:00:00" and
  .inbounds.vless.limit.cycleEnd=="2026-10-07 18:00:00"
' "$TRAFFIC_FILE" >/dev/null
BASH_LIMITS

# nft JSON snapshots are grouped by inbound tag across upload/download rules.
SBCTL_TESTING=1 \
SBCTL_CONFIG_DIR="$TMP/nft/cfg" \
SBCTL_CONFIG_FILE="$TMP/nft/cfg/config.json" \
SBCTL_META_FILE="$TMP/nft/meta.json" \
SBCTL_TRAFFIC_FILE="$TMP/nft/traffic.json" \
SBCTL_CERT_DIR="$TMP/nft/cfg/certs" \
SBCTL_LOCK_FILE="$TMP/nft/lock" \
bash <<'BASH_NFT'
set -Eeuo pipefail
source ./sbctl.sh
nft() {
  [[ $1 == -j ]] || return 1
  cat <<'JSON'
{"nftables":[
  {"rule":{"comment":"sbctl-traffic:vless","expr":[{"counter":{"packets":2,"bytes":100}}]}},
  {"rule":{"comment":"sbctl-traffic:count:vless","expr":[{"counter":{"packets":3,"bytes":250}}]}},
  {"rule":{"comment":"sbctl-traffic:block:vless","expr":[{"counter":{"packets":4,"bytes":999}}]}},
  {"rule":{"comment":"unrelated","expr":[{"counter":{"packets":1,"bytes":999}}]}},
  {"rule":{"comment":"sbctl-traffic:socks","expr":[{"counter":{"packets":1,"bytes":50}}]}}
]}
JSON
}
rows=$(traffic_read_nft_counters | sort)
grep -Fxq $'socks\t50' <<<"$rows"
grep -Fxq $'vless\t350' <<<"$rows"
! traffic_clear_nft_rules 2>/dev/null
BASH_NFT

# Real nft JSON includes table and chain objects alongside rule objects. Those
# non-rule nodes must not be mistaken for foreign rules in an sbctl-owned table.
SBCTL_TESTING=1 \
SBCTL_CONFIG_DIR="$TMP/nft-owned/cfg" \
SBCTL_CONFIG_FILE="$TMP/nft-owned/cfg/config.json" \
SBCTL_META_FILE="$TMP/nft-owned/meta.json" \
SBCTL_TRAFFIC_FILE="$TMP/nft-owned/traffic.json" \
SBCTL_CERT_DIR="$TMP/nft-owned/cfg/certs" \
SBCTL_LOCK_FILE="$TMP/nft-owned/lock" \
CASE_DIR="$TMP/nft-owned" \
bash <<'BASH_NFT_OWNED'
set -Eeuo pipefail
source ./sbctl.sh
mkdir -p "$CASE_DIR"
nft() {
  if [[ ${1-} == -j ]]; then
    cat <<'JSON'
{"nftables":[
  {"metainfo":{"version":"1.0.9"}},
  {"table":{"family":"inet","name":"sbctl_traffic"}},
  {"chain":{"family":"inet","table":"sbctl_traffic","name":"input"}},
  {"chain":{"family":"inet","table":"sbctl_traffic","name":"output"}},
  {"rule":{"family":"inet","table":"sbctl_traffic","chain":"input","comment":"sbctl-traffic:count:vless","expr":[]}}
]}
JSON
    return 0
  fi
  local IFS=' '; printf '%s\n' "$*" >>"$CASE_DIR/nft-calls"
}
traffic_clear_nft_rules
grep -Fxq 'delete table inet sbctl_traffic' "$CASE_DIR/nft-calls"
BASH_NFT_OWNED

# iptables fallback counts only accounting rules and places DROP rules before
# the counter/RETURN rules for an exhausted inbound.
SBCTL_TESTING=1 \
SBCTL_TRAFFIC_BACKEND=iptables \
SBCTL_TRAFFIC_TODAY=2026-08-24 \
SBCTL_TRAFFIC_NOW='2026-08-24 12:01:00' \
SBCTL_CONFIG_DIR="$TMP/iptables/cfg" \
SBCTL_CONFIG_FILE="$TMP/iptables/cfg/config.json" \
SBCTL_META_FILE="$TMP/iptables/meta.json" \
SBCTL_TRAFFIC_FILE="$TMP/iptables/traffic.json" \
SBCTL_CERT_DIR="$TMP/iptables/cfg/certs" \
SBCTL_LOCK_FILE="$TMP/iptables/lock" \
CASE_DIR="$TMP/iptables" \
bash <<'BASH_IPTABLES'
set -Eeuo pipefail
source ./sbctl.sh
trap - ERR
mkdir -p "$CASE_DIR"
write_default_config
tmp=$(temp_file)
jq '.inbounds=[{"type":"vless","tag":"vless","listen":"0.0.0.0","listen_port":17225,"users":[]}]' "$CONFIG_FILE" >"$tmp"
mv -f "$tmp" "$CONFIG_FILE"
traffic_init_file
tmp=$(temp_file)
jq '.enabled=true | .limitsEnabled=true | .backend="iptables" |
  .inbounds.vless={protocol:"vless",port:17225,deleted:false,daily:{},limit:{enabled:true,quotaBytes:100,
    anchorDay:24,anchorTime:"12:00:00",cycleStart:"2026-08-24 12:00:00",cycleEnd:"2026-09-24 12:00:00",usedBytes:100}}' \
  "$TRAFFIC_FILE" >"$tmp"
install -m 600 "$tmp" "$TRAFFIC_FILE"; rm -f "$tmp"

IPTABLES_MODE=read
iptables() {
  if [[ $IPTABLES_MODE == read && ${3-} == -L ]]; then
    cat <<'TABLE'
Chain mock (1 references)
 pkts bytes target prot opt in out source destination
 1 100 RETURN tcp -- * * 0.0.0.0/0 0.0.0.0/0 /* sbctl-traffic:count:vless */
 1 999 DROP tcp -- * * 0.0.0.0/0 0.0.0.0/0 /* sbctl-traffic:block:vless */
TABLE
    return 0
  fi
  if [[ ${3-} == -S || ${3-} == -C ]]; then return 1; fi
  local IFS=' '; printf '%s\n' "$*" >>"$CASE_DIR/iptables-calls"
}
rows=$(traffic_read_iptables_counters)
[[ $(grep -Fc $'vless\t100' <<<"$rows") == 2 ]]
! grep -Fq $'vless\t999' <<<"$rows"

IPTABLES_MODE=write
traffic_restore_iptables_rules
drop_line=$(grep -nF -- '--comment sbctl-traffic:block:vless -j DROP' "$CASE_DIR/iptables-calls" | head -1 | cut -d: -f1)
count_line=$(grep -nF -- '--comment sbctl-traffic:count:vless -j RETURN' "$CASE_DIR/iptables-calls" | head -1 | cut -d: -f1)
[[ -n $drop_line && -n $count_line && $drop_line -lt $count_line ]]
BASH_IPTABLES

# Rule generation covers TCP, SOCKS TCP+UDP and Hysteria2 UDP, and the
# systemd timer is installed as an sbctl-owned one-minute collector.
mkdir -p "$TMP/runtime/bin" "$TMP/runtime/systemd" "$TMP/runtime/cfg"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/runtime/bin/sbctl"
chmod 755 "$TMP/runtime/bin/sbctl"
SBCTL_TESTING=1 \
SBCTL_TRAFFIC_BACKEND=nft \
SBCTL_CONFIG_DIR="$TMP/runtime/cfg" \
SBCTL_CONFIG_FILE="$TMP/runtime/cfg/config.json" \
SBCTL_META_FILE="$TMP/runtime/meta.json" \
SBCTL_TRAFFIC_FILE="$TMP/runtime/traffic.json" \
SBCTL_CERT_DIR="$TMP/runtime/cfg/certs" \
SBCTL_LOCK_FILE="$TMP/runtime/lock" \
SBCTL_SYSTEMD_UNIT_DIR="$TMP/runtime/systemd" \
SBCTL_COMMAND_PATH="$TMP/runtime/bin/sbctl" \
SBCTL_SYMLINK_PATH="$TMP/runtime/bin/sbctl-link" \
CASE_DIR="$TMP/runtime" \
bash <<'BASH_RUNTIME'
set -Eeuo pipefail
source ./sbctl.sh
write_default_config
tmp=$(temp_file)
jq '.inbounds=[
  {"type":"vless","tag":"vless","listen":"0.0.0.0","listen_port":17225,"users":[]},
  {"type":"socks","tag":"socks","listen":"0.0.0.0","listen_port":5000,"users":[]},
  {"type":"hysteria2","tag":"hy2","listen":"0.0.0.0","listen_port":24443,"users":[]}
]' "$CONFIG_FILE" >"$tmp"; mv -f "$tmp" "$CONFIG_FILE"
traffic_set_backend nft
traffic_init_file
tmp=$(temp_file)
jq '.limitsEnabled=true | .inbounds.vless={protocol:"vless",port:17225,deleted:false,daily:{},limit:{enabled:true,quotaBytes:100,anchorDay:24,anchorTime:"12:00:00",cycleStart:"2026-08-24 12:00:00",cycleEnd:"2026-09-24 12:00:00",usedBytes:100}}' "$TRAFFIC_FILE" >"$tmp"
install -m 600 "$tmp" "$TRAFFIC_FILE"; rm -f "$tmp"

nft() {
  if [[ $1 == -j ]]; then printf '%s\n' '{"nftables":[]}'; return 0; fi
  local IFS=' '; printf '%s\n' "$*" >>"$CASE_DIR/nft-calls"
}
traffic_rules_restore
grep -Fq 'add rule inet sbctl_traffic input tcp dport 17225 comment "sbctl-traffic:block:vless" drop' "$CASE_DIR/nft-calls"
grep -Fq 'add rule inet sbctl_traffic input tcp dport 17225 counter comment "sbctl-traffic:count:vless"' "$CASE_DIR/nft-calls"
grep -Fq 'add rule inet sbctl_traffic input tcp dport 5000 counter comment "sbctl-traffic:count:socks"' "$CASE_DIR/nft-calls"
grep -Fq 'add rule inet sbctl_traffic input udp dport 5000 counter comment "sbctl-traffic:count:socks"' "$CASE_DIR/nft-calls"
grep -Fq 'add rule inet sbctl_traffic input udp dport 24443 counter comment "sbctl-traffic:count:hy2"' "$CASE_DIR/nft-calls"
! grep -Fq 'sbctl-traffic:block:socks' "$CASE_DIR/nft-calls"
! grep -Fq 'udp dport 17225' "$CASE_DIR/nft-calls"

init_system() { printf systemd; }
systemctl() { local IFS=' '; printf '%s\n' "$*" >>"$CASE_DIR/systemctl-calls"; }
traffic_timer_install
grep -Fxq 'OnUnitActiveSec=1min' "$TRAFFIC_SYSTEMD_TIMER"
grep -Fxq 'NoNewPrivileges=true' "$TRAFFIC_SYSTEMD_SERVICE"
grep -Fxq 'ProtectSystem=strict' "$TRAFFIC_SYSTEMD_SERVICE"
grep -Fxq "ExecStart=$QUICK_COMMAND internal-traffic-collect" "$TRAFFIC_SYSTEMD_SERVICE"
[[ $(meta_resource_get trafficService) == "$TRAFFIC_SYSTEMD_SERVICE" ]]
[[ $(meta_resource_get trafficTimer) == "$TRAFFIC_SYSTEMD_TIMER" ]]
traffic_timer_remove
[[ ! -e $TRAFFIC_SYSTEMD_SERVICE && ! -e $TRAFFIC_SYSTEMD_TIMER ]]
BASH_RUNTIME

# Returning from either quota-menu state is a successful navigation action;
# it must not bubble the preceding boolean probe's status up to traffic_menu.
SBCTL_TESTING=1 bash <<'BASH_MENU_RETURN'
set -Eeuo pipefail
source ./sbctl.sh
clear_screen() { :; }
traffic_is_enabled() { return 0; }
traffic_collect() { :; }
traffic_limits_show() { :; }
traffic_limits_are_enabled() { return 1; }
traffic_limit_menu <<<"0" >/dev/null
traffic_limits_are_enabled() { return 0; }
traffic_limit_menu <<<"0" >/dev/null
BASH_MENU_RETURN

printf 'traffic accounting unit checks passed.\n'
