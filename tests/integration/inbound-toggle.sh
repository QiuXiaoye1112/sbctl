#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"
CASE_DIR=$(mktemp -d)
trap 'rm -rf "$CASE_DIR"' EXIT
SBCTL_TESTING=1 \
SBCTL_TRAFFIC_NOW='2026-09-23 12:00:00' \
SBCTL_CONFIG_DIR="$CASE_DIR/config" \
SBCTL_CONFIG_FILE="$CASE_DIR/config/config.json" \
SBCTL_META_FILE="$CASE_DIR/meta.json" \
SBCTL_TRAFFIC_FILE="$CASE_DIR/traffic.json" \
SBCTL_CERT_DIR="$CASE_DIR/config/certs" \
SBCTL_LOCK_FILE="$CASE_DIR/lock" \
bash <<'BASH'
set -Eeuo pipefail
source ./sbctl.sh
ensure_dependencies() { :; }
sing_box_installed() { return 1; }
service_is_active() { return 0; }
restart_service_checked() { return 0; }
service_restart() { return 0; }
port_in_use_os() { return 1; }
write_default_config
candidate=$(temp_file)
jq '.inbounds=[{type:"vless",tag:"vless",listen:"0.0.0.0",listen_port:17225,users:[]},{type:"socks",tag:"socks",listen:"0.0.0.0",listen_port:5000,users:[]}] | .route.rules=[{inbound:["vless"],outbound:"direct"}]' "$CONFIG_FILE" >"$candidate"
install -m 600 "$candidate" "$CONFIG_FILE"; rm -f "$candidate"
traffic_init_file
candidate=$(temp_file)
jq '.inbounds.vless={protocol:"vless",port:17225,daily:{},cycles:{},limit:{enabled:true,quotaBytes:1000,usedBytes:123}}' "$TRAFFIC_FILE" >"$candidate"
install -m 600 "$candidate" "$TRAFFIC_FILE"; rm -f "$candidate"
disable_inbound vless 1 >/dev/null
jq -e '.inbounds|length==1' "$CONFIG_FILE" >/dev/null
jq -e '.disabledInbounds.vless.config.listen_port==17225 and .disabledInbounds.vless.position==0' "$META_FILE" >/dev/null
jq -e '.inbounds.vless.limit.usedBytes==123 and .inbounds.vless.deleted==false and .inbounds.vless.disabled==true' "$TRAFFIC_FILE" >/dev/null
[[ $(list_inbounds) == *'已禁用'* ]]
port_in_use_os() { return 0; }
if enable_inbound vless; then exit 1; fi
jq -e '.inbounds|length==1' "$CONFIG_FILE" >/dev/null
port_in_use_os() { return 1; }
enable_inbound vless >/dev/null
jq -e '.inbounds[0].tag=="vless" and .inbounds[1].tag=="socks"' "$CONFIG_FILE" >/dev/null
jq -e '.disabledInbounds.vless==null' "$META_FILE" >/dev/null
jq -e '.inbounds.vless.limit.usedBytes==123 and .inbounds.vless.disabled==false' "$TRAFFIC_FILE" >/dev/null
restart_service_checked() { return 1; }
if disable_inbound vless 1; then exit 1; fi
jq -e '.inbounds[0].tag=="vless"' "$CONFIG_FILE" >/dev/null
jq -e '.disabledInbounds.vless==null' "$META_FILE" >/dev/null
restart_service_checked() { return 0; }
hy2_hop_sync() { :; }
disable_inbound vless 1 >/dev/null
confirm() { return 0; }
delete_inbound vless 1 >/dev/null
jq -e '.disabledInbounds.vless==null and .inbounds.vless==null' "$META_FILE" >/dev/null
jq -e '.inbounds.vless.limit==null' "$TRAFFIC_FILE" >/dev/null
jq -e '.route.rules|all(.[]; (.inbound // [])|index("vless")==null)' "$CONFIG_FILE" >/dev/null
candidate=$(temp_file)
jq '.inbounds += [{type:"hysteria2",tag:"hy2",listen:"0.0.0.0",listen_port:24443,users:[]}]' "$CONFIG_FILE" >"$candidate"
install -m 600 "$candidate" "$CONFIG_FILE"; rm -f "$candidate"
candidate=$(temp_file)
jq '.inbounds.hy2.hysteria2PortHopping={enabled:true,range:"30000-30010"}' "$META_FILE" >"$candidate"
install -m 600 "$candidate" "$META_FILE"; rm -f "$candidate"
[[ $(hy2_hop_enabled_count) == 1 ]]
disable_inbound hy2 1 >/dev/null
[[ $(hy2_hop_enabled_count) == 0 ]]
enable_inbound hy2 >/dev/null
[[ $(hy2_hop_enabled_count) == 1 ]]
BASH
printf 'inbound toggle integration checks passed.\n'
