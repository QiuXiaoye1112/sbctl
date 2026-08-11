#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

bash -n sbctl.sh
bash -n src/certificate/core.sh
bash -n src/certificate/lifecycle.sh
bash -n src/uninstall.sh
bash -n src/menu.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
MOCK="$TMP/mock"
CASE="$TMP/case"
mkdir -p "$MOCK" "$CASE/certs" "$CASE/bin" "$CASE/systemd" "$CASE/hooks"

cat >"$MOCK/systemctl" <<'SH'
#!/usr/bin/env sh
case "$1" in
  is-active|is-enabled|list-unit-files) exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$MOCK/systemctl"

# Seed a schema-1 metadata file and a legacy certificate pair to verify that
# upgrades preserve inbound metadata while registering old certificate copies.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=legacy.example.com' \
  -keyout "$CASE/certs/legacy.example.com.key" -out "$CASE/certs/legacy.example.com.crt" >/dev/null 2>&1
cat >"$CASE/meta.json" <<'JSON'
{"schema":1,"inbounds":{"old":{"host":"1.2.3.4"}}}
JSON

# A second pair is used to exercise the new atomic import/delete path.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=imported.example.com' \
  -keyout "$CASE/imported.key" -out "$CASE/imported.crt" >/dev/null 2>&1

CASE="$CASE" \
PATH="$MOCK:$PATH" \
SBCTL_TESTING=1 \
SBCTL_CONFIG_DIR="$CASE/cfg" \
SBCTL_CONFIG_FILE="$CASE/cfg/config.json" \
SBCTL_META_FILE="$CASE/meta.json" \
SBCTL_CERT_DIR="$CASE/certs" \
SBCTL_BACKUP_DIR="$CASE/backups" \
SBCTL_DATA_DIR="$CASE/data" \
SBCTL_SYSTEMD_UNIT_DIR="$CASE/systemd" \
SBCTL_COMMAND_PATH="$CASE/bin/sbctl" \
SBCTL_SYMLINK_PATH="$CASE/bin/sbctl-link" \
SBCTL_LOCK_FILE="$CASE/lock" \
SBCTL_CERTBOT_HOOK_DIR="$CASE/hooks" \
SBCTL_CERTBOT_VENV="$CASE/certbot-venv" \
SBCTL_CERTBOT_CONFIG_DIR="$CASE/certbot-config" \
SBCTL_CERTBOT_WORK_DIR="$CASE/certbot-work" \
SBCTL_CERTBOT_LOGS_DIR="$CASE/certbot-logs" \
bash <<'BASH'
set -Eeuo pipefail
source ./sbctl.sh

init_meta
[[ $(jq -r .schema "$META_FILE") == 2 ]]
[[ $(jq -r '.inbounds.old.host' "$META_FILE") == 1.2.3.4 ]]
[[ $(meta_cert_get_field legacy.example.com source) == legacy ]]
[[ $(meta_cert_get_field legacy.example.com autoRenew) == false ]]

write_default_config
import_certificate imported.example.com "$CASE/imported.crt" "$CASE/imported.key"
[[ -s $CERT_DIR/imported.example.com.crt && -s $CERT_DIR/imported.example.com.key ]]
[[ $(meta_cert_get_field imported.example.com source) == imported ]]
[[ $(managed_certificate_count) == 2 ]]

tmp=$(temp_file)
jq --arg cert "$CERT_DIR/imported.example.com.crt" --arg key "$CERT_DIR/imported.example.com.key" '
  .inbounds=[{type:"hysteria2",tag:"uses-cert",listen:"127.0.0.1",listen_port:24445,
    users:[{name:"u",password:"p"}],tls:{enabled:true,server_name:"imported.example.com",
    certificate_path:$cert,key_path:$key}}]
' "$CONFIG_FILE" >"$tmp"
mv -f "$tmp" "$CONFIG_FILE"

# Deletion must be blocked while a TLS inbound references the certificate.
delete_certificate imported.example.com 1
[[ -e $CERT_DIR/imported.example.com.crt ]]
meta_cert_exists imported.example.com

tmp=$(temp_file)
jq '.inbounds=[]' "$CONFIG_FILE" >"$tmp"
mv -f "$tmp" "$CONFIG_FILE"
delete_certificate imported.example.com 1
[[ ! -e $CERT_DIR/imported.example.com.crt && ! -e $CERT_DIR/imported.example.com.key ]]
! meta_cert_exists imported.example.com

# Safe uninstall helpers may remove a recorded custom directory, but never a
# dangerous root path.
owned="$CASE/owned"
mkdir -p "$owned"
meta_resource_register ownedDir "$owned"
_uninstall_snapshot_metadata
_safe_remove_sbctl_dir "$owned" ownedDir
[[ ! -e $owned ]]
if _safe_remove_sbctl_dir / ownedDir; then
  echo "dangerous root path was accepted" >&2
  exit 1
fi
rm -f "$SNAPSHOT_META"

help=$(show_help)
grep -Fq "uninstall --erase" <<<"$help"
grep -Fq "cert renew-auto" <<<"$help"
BASH

echo 'certificate/uninstall lifecycle tests passed.'
