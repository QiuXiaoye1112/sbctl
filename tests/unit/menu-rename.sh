#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export SBCTL_TESTING=1 SBCTL_CONFIG_FILE="$TMP/config.json"
source ./sbctl.sh
printf '%s\n' '{"inbounds":[{"tag":"old","type":"anytls","listen_port":1234,"users":[]}],"outbounds":[]}' >"$CONFIG_FILE"
clear_screen() { :; }
pause() { :; }
run_menu_action() {
  if [[ $1 == rename_inbound ]]; then
    jq --arg tag "$3" '.inbounds[0].tag=$tag' "$CONFIG_FILE" >"$TMP/next"
    mv "$TMP/next" "$CONFIG_FILE"
  fi
}
output=$(manage_inbound_menu old <<'INPUT'
3
1
new
0
0
INPUT
)
[[ $output == *'修改入站信息 · new'* ]]
[[ $output == *'入站 · new'* ]]
printf '%s\n' '{"inbounds":[{"tag":"old","type":"anytls","listen_port":1234,"users":[]}],"outbounds":[]}' >"$CONFIG_FILE"
run_menu_action() { :; }
output=$(manage_inbound_menu old <<'INPUT'
3
1
new
0
0
INPUT
)
[[ $output == *'修改入站信息 · old'* ]]
[[ $output != *'入站 · new'* ]]
printf 'menu rename navigation passed.\n'
