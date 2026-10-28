#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export SBCTL_TESTING=1 SBCTL_CONFIG_DIR="$TMP/config" SBCTL_CONFIG_FILE="$TMP/config/config.json" SBCTL_META_FILE="$TMP/meta.json" SBCTL_CERT_DIR="$TMP/certs" SBCTL_BACKUP_DIR="$TMP/backups"
source ./sbctl.sh
write_default_config
traffic_remove_all() { touch "$TMP/traffic-stop-attempted"; return 1; }
_remove_renewal_jobs() { :; }
_remove_managed_certificates() { touch "$TMP/certificates-removed"; }
_remove_certbot_environment() { touch "$TMP/environment-removed"; }
_remove_sing_box_core() { touch "$TMP/core-removed"; }
_remove_config_and_metadata() { rm -f "$CONFIG_FILE" "$META_FILE"; }
_remove_quick_command_and_libs() { :; }
if _sbctl_remove_all <<<DELETE; then exit 1; fi
[[ -f $TMP/traffic-stop-attempted ]]
[[ -f $CONFIG_FILE && -f $META_FILE ]]
[[ ! -e $TMP/environment-removed ]]
[[ ! -e $TMP/certificates-removed && ! -e $TMP/core-removed ]]
mkdir -p "$BACKUP_DIR"
printf '%s\n' user >"$BACKUP_DIR/user-file"
_uninstall_snapshot_metadata
if _remove_backups; then exit 1; fi
[[ -f $BACKUP_DIR/user-file ]]
rm -f "$SNAPSHOT_META"
# A recorded directory is required even for paths otherwise known to sbctl.
mkdir -p "$TMP/user-certbot"
printf 'user data\n' >"$TMP/user-certbot/keep"
CERTBOT_CONFIG_DIR="$TMP/user-certbot"
_uninstall_snapshot_metadata
if _safe_remove_sbctl_dir "$CERTBOT_CONFIG_DIR" certbotConfigDir; then exit 1; fi
[[ -f $CERTBOT_CONFIG_DIR/keep ]]
rm -f "$SNAPSHOT_META"
printf 'uninstall failure and ownership tests passed.\n'
