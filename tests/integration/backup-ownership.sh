#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
export SBCTL_TESTING=1 SBCTL_CONFIG_DIR="$test_dir/config" SBCTL_CONFIG_FILE="$test_dir/config/config.json"
export SBCTL_META_FILE="$test_dir/meta.json" SBCTL_CERT_DIR="$test_dir/certs" SBCTL_TRAFFIC_FILE="$test_dir/traffic.json"
export SBCTL_BACKUP_DIR="$test_dir/backups" SBCTL_LOCK_FILE="$test_dir/lock"
export CASE_DIR="$test_dir"
bash <<'BASH'
set -Eeuo pipefail
source ./sbctl.sh
ensure_dependencies() { :; }
confirm() { return 0; }
restart_service_checked() { return 0; }
hy2_hop_sync() { return 0; }
traffic_runtime_ensure() { return 0; }
write_default_config

# An older archive predates local resource registration and must not replace
# local ownership with resource paths from the machine that created it.
jq '.managedResources={backupDir:"/foreign/backups",singBoxBinaryPath:"/foreign/sing-box"} | .singBox={binary:"/foreign/sing-box"} | .inbounds.old={host:"backup.example"}' "$META_FILE" >"$CASE_DIR/old-meta"
cp "$META_FILE" "$CASE_DIR/local-meta"
cp "$CASE_DIR/old-meta" "$META_FILE"
tar -czf "$CASE_DIR/old.tar.gz" -C / "${CONFIG_FILE#/}" "${META_FILE#/}"
cp "$CASE_DIR/local-meta" "$META_FILE"
meta_resource_register singBoxBinaryPath /local/sing-box
jq '.singBox={binary:"/local/sing-box"}' "$META_FILE" >"$CASE_DIR/with-local-core"
cp "$CASE_DIR/with-local-core" "$META_FILE"
backup_all "$CASE_DIR/current.tar.gz" >/dev/null
tar -xOzf "$CASE_DIR/current.tar.gz" "${META_FILE#/}" | jq -e --arg path "$BACKUP_DIR" '.managedResources.backupDir==$path' >/dev/null

restore_backup "$CASE_DIR/old.tar.gz" >/dev/null
jq -e --arg path "$BACKUP_DIR" '.managedResources.backupDir==$path and .managedResources.singBoxBinaryPath=="/local/sing-box" and .singBox.binary=="/local/sing-box" and .inbounds.old.host=="backup.example"' "$META_FILE" >/dev/null

# A legacy archive with no metadata also retains local ownership records.
tar -czf "$CASE_DIR/no-meta.tar.gz" -C / "${CONFIG_FILE#/}"
restore_backup "$CASE_DIR/no-meta.tar.gz" >/dev/null
jq -e --arg path "$BACKUP_DIR" '.managedResources.backupDir==$path and .managedResources.singBoxBinaryPath=="/local/sing-box" and .singBox.binary=="/local/sing-box" and .inbounds=={}' "$META_FILE" >/dev/null

# Failed restores must put the current metadata back, including ownership.
cp "$META_FILE" "$CASE_DIR/before-failure"
restart_service_checked() { return 1; }
if (restore_backup "$CASE_DIR/old.tar.gz" >/dev/null 2>&1); then
  printf 'restore unexpectedly succeeded after restart failure\n' >&2
  exit 1
fi
cmp "$CASE_DIR/before-failure" "$META_FILE"
restart_service_checked() { return 0; }
_uninstall_snapshot_metadata
_remove_backups
[[ ! -e $BACKUP_DIR ]]
rm -f "$SNAPSHOT_META"

# A directory that predates sbctl and lacks its marker must not be claimed.
mkdir "$BACKUP_DIR"
printf 'keep\n' >"$BACKUP_DIR/user-file"
meta_resource_remove backupDir
backup_all "$CASE_DIR/unowned.tar.gz" >/dev/null
[[ -z $(meta_resource_get backupDir) && -f $BACKUP_DIR/user-file ]]

# Without current metadata, a foreign archive must not assert local ownership.
rm -f "$META_FILE"
restore_backup "$CASE_DIR/old.tar.gz" >/dev/null
jq -e '.managedResources=={} and (has("singBox")|not)' "$META_FILE" >/dev/null
BASH
printf 'backup ownership and old-archive restore checks passed.\n'
