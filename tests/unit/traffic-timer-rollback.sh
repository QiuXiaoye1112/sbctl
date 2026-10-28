#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export SBCTL_TESTING=1 SBCTL_CONFIG_FILE="$TMP/config" SBCTL_TRAFFIC_FILE="$TMP/traffic"
source "$ROOT/sbctl.sh"
printf '%s\n' '{"backend":"nft","enabled":false}' >"$TRAFFIC_FILE"
require_root() { :; }; ensure_config() { :; }; traffic_ensure_backend() { :; }
traffic_backend() { echo iptables; }; traffic_backend_conflicts() { return 1; }
traffic_set_enabled() { jq --argjson v "$1" '.enabled=$v' "$TRAFFIC_FILE" >"$TMP/t"; mv "$TMP/t" "$TRAFFIC_FILE"; }
traffic_sync_inventory() { :; }
traffic_rules_restore_serialized() { echo "${1:-iptables}" >>"$TMP/log"; jq --arg v "${1:-iptables}" '.backend=$v' "$TRAFFIC_FILE" >"$TMP/t"; mv "$TMP/t" "$TRAFFIC_FILE"; }
traffic_timer_install() { return 1; }; traffic_timer_remove() { echo remove >>"$TMP/log"; }
if traffic_enable; then exit 1; fi
[[ $(jq -r .backend "$TRAFFIC_FILE") == nft && $(jq -r .enabled "$TRAFFIC_FILE") == false ]]
[[ $(cat "$TMP/log") == $'iptables\nnft\nremove' ]]
printf '%s\n' '{"backend":"nft","enabled":true}' >"$TRAFFIC_FILE"; : >"$TMP/log"
if traffic_enable; then exit 1; fi
[[ $(jq -r .backend "$TRAFFIC_FILE") == nft && $(jq -r .enabled "$TRAFFIC_FILE") == true ]]
[[ $(cat "$TMP/log") == $'iptables\nnft' ]]
echo 'timer backend rollback tests passed'
