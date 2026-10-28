#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export SBCTL_CONFIG_DIR="$tmp/config" SBCTL_CONFIG_FILE="$tmp/config/config.json" SBCTL_META_FILE="$tmp/meta.json" SBCTL_CERT_DIR="$tmp/certs" SBCTL_TRAFFIC_FILE="$tmp/traffic.json" SBCTL_BACKUP_DIR="$tmp/backups"
mkdir -p "$SBCTL_CONFIG_DIR"
printf '%s\n' '{"inbounds":[],"outbounds":[]}' > "$SBCTL_CONFIG_FILE"
python3 - "$tmp" "${SBCTL_CONFIG_FILE#/}" "${SBCTL_META_FILE#/}" <<'PY'
import io, sys, tarfile
root, config, meta = sys.argv[1:]
for kind in ('symlink', 'hardlink', 'badmeta', 'traversal'):
    with tarfile.open(f'{root}/{kind}.tar.gz', 'w:gz') as t:
        data = b'{"inbounds":[],"outbounds":[]}'
        info = tarfile.TarInfo(config); info.size = len(data); t.addfile(info, io.BytesIO(data))
        if kind == 'badmeta':
            info = tarfile.TarInfo(meta); data = b'[]'; info.size = len(data); t.addfile(info, io.BytesIO(data))
        elif kind == 'traversal':
            info = tarfile.TarInfo('../escape'); info.size = 1; t.addfile(info, io.BytesIO(b'x'))
        else:
            info = tarfile.TarInfo('evil'); info.type = tarfile.SYMTYPE if kind == 'symlink' else tarfile.LNKTYPE; info.linkname = '/tmp/escape'; t.addfile(info)
PY
printf invalid > "$tmp/invalid.tar.gz"
for kind in symlink hardlink badmeta traversal invalid; do
  if SBCTL_TESTING=1 bash -c 'source ./sbctl.sh; ensure_dependencies() { :; }; ensure_config() { :; }; validate_candidate() { :; }; restore_backup "$1"' _ "$tmp/$kind.tar.gz" >/dev/null 2>&1; then
    printf 'unsafe restore accepted: %s\n' "$kind" >&2; exit 1
  fi
  jq -e '.inbounds==[]' "$SBCTL_CONFIG_FILE" >/dev/null
 done
printf 'restore safety checks passed.\n'
