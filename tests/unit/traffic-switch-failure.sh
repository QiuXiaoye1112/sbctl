#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export SBCTL_TESTING=1 SBCTL_CONFIG_FILE="$TMP/config.json" SBCTL_TRAFFIC_FILE="$TMP/traffic.json"
source "$ROOT/sbctl.sh"
printf '{}\n' >"$CONFIG_FILE"
printf '{"backend":"nft"}\n' >"$TRAFFIC_FILE"
traffic_backend() { printf iptables; }
traffic_backend_conflicts() { return 1; }
traffic_restore_iptables_rules() { echo build >>"$TMP/log"; return "${BUILD_FAIL:-0}"; }
traffic_clear_iptables_rules() { echo clear-new >>"$TMP/log"; }
traffic_clear_nft_rules() { echo clear-old >>"$TMP/log"; }
traffic_restore_nft_rules() { echo restore-old >>"$TMP/log"; }
traffic_set_backend() { echo set >>"$TMP/log"; return "${SET_FAIL:-0}"; }
BUILD_FAIL=1
if traffic_rules_restore; then exit 1; fi
[[ $(cat "$TMP/log") == $'build\nclear-new' ]]
: >"$TMP/log"
BUILD_FAIL=0 SET_FAIL=1
if traffic_rules_restore; then exit 1; fi
[[ $(cat "$TMP/log") == $'build\nclear-old\nset\nrestore-old\nclear-new' ]]
[[ $(jq -r .backend "$TRAFFIC_FILE") == nft ]]
# The enable entry point must not overwrite the recorded backend before the
# switching logic has a chance to preserve it.
require_root() { :; }
ensure_config() { :; }
traffic_ensure_backend() { :; }
traffic_set_enabled() { echo "enabled:$1" >>"$TMP/log"; }
traffic_sync_inventory() { return "${SYNC_FAIL:-0}"; }
traffic_rules_restore_serialized() { echo "recorded:$(traffic_recorded_backend)" >>"$TMP/log"; return 1; }
: >"$TMP/log"
SYNC_FAIL=0
if traffic_enable; then exit 1; fi
[[ $(cat "$TMP/log") == $'enabled:true\nrecorded:nft\nenabled:false' ]]
: >"$TMP/log"
SYNC_FAIL=1
if traffic_enable; then exit 1; fi
[[ $(cat "$TMP/log") == $'enabled:true\nenabled:false' ]]
printf 'traffic backend switching failure tests passed.\n'
