#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/sing-box" <<'SH'
#!/usr/bin/env bash
set -e
case ${1-} in
  version) echo 'sing-box version 1.13.15' ;;
  check) jq -e . "$3" >/dev/null ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP/sing-box"

mkdir -p "$TMP/cfg"
cat >"$TMP/cfg/config.json" <<'JSON'
{
  "inbounds": [
    {
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": 8080,
      "users": []
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ],
  "route": {
    "final": "direct"
  }
}
JSON

SBCTL_SING_BOX_BIN="$TMP/sing-box" \
SBCTL_CONFIG_DIR="$TMP/cfg" \
SBCTL_CONFIG_FILE="$TMP/cfg/config.json" \
SBCTL_META_FILE="$TMP/meta.json" \
SBCTL_CERT_DIR="$TMP/cfg/certs" \
SBCTL_BACKUP_DIR="$TMP/backups" \
SBCTL_LOCK_FILE="$TMP/lock" \
bash -c '
  set -Eeuo pipefail
  source ./sbctl.sh

  ensure_config
  [[ $(jq -r ".inbounds[0].tag" "$CONFIG_FILE") == legacy-shadowsocks-1 ]]
  [[ $(jq -r ".outbounds[0].tag" "$CONFIG_FILE") == direct ]]
  [[ $(jq -r ".route.final" "$CONFIG_FILE") == direct ]]
  ls "$BACKUP_DIR"/pre-tag-migration-*.json >/dev/null

  output=$(list_inbounds)
  grep -Fq "legacy-shado..." <<<"$output"
  grep -Fq "shadow..." <<<"$output"
  grep -Fq "8080" <<<"$output"
  [[ $(show_inbound legacy-shadowsocks-1 | jq -r .tag) == legacy-shadowsocks-1 ]]

  ensure_dependencies(){ :; }
  delete_inbound legacy-shadowsocks-1 1
  [[ $(jq ".inbounds|length" "$CONFIG_FILE") == 0 ]]
'

echo 'legacy config migration tests passed.'
