#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
export SBCTL_TESTING=1 SBCTL_CONFIG_DIR="$test_dir/config" SBCTL_CONFIG_FILE="$test_dir/config/config.json"
export SBCTL_META_FILE="$test_dir/meta.json" SBCTL_TRAFFIC_FILE="$test_dir/traffic.json" SBCTL_LOCK_FILE="$test_dir/lock"
export SBCTL_CERT_DIR="$test_dir/certs"
export SBCTL_TRAFFIC_NOW='2026-01-01 12:00:00'
bash <<'BASH'
set -Eeuo pipefail
source ./sbctl.sh
write_default_config
jq '.inbounds=[{tag:"new",type:"socks",listen_port:12345}]' "$CONFIG_FILE" >"$CONFIG_FILE.tmp"
mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
traffic_init_file
jq '.inbounds.old={daily:{"2026-01-01":123},cycles:{}}' "$TRAFFIC_FILE" >"$TRAFFIC_FILE.tmp"
mv "$TRAFFIC_FILE.tmp" "$TRAFFIC_FILE"
traffic_after_config_change old new
jq -e '.inbounds.old==null and .inbounds.new.daily["2026-01-01"]==123' "$TRAFFIC_FILE" >/dev/null

# An enabled collector must still report a rule synchronization failure.
traffic_collect() { return 0; }
traffic_rules_restore_serialized() { return 1; }
traffic_set_enabled true
if traffic_after_config_change new newer; then
  printf 'rule restore failure was ignored\n' >&2
  exit 1
fi
BASH
printf 'disabled traffic rename and synchronization failure checks passed.\n'
