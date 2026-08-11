#!/usr/bin/env sh
set -eu

REPO="QiuXiaoye1112/sbctl"
TARGET="/usr/local/sbin/sbctl"
SYMLINK="/usr/local/bin/sbctl"
DIST_URL="${SBCTL_DIST_URL:-https://raw.githubusercontent.com/${REPO}/refs/heads/main/dist/sbctl}"

[ "$(id -u)" -eq 0 ] || { echo '[sbctl] 请使用 root 运行。' >&2; exit 1; }
[ -f /etc/alpine-release ] || { echo '[sbctl] 此入口仅用于 Alpine Linux。' >&2; exit 1; }
apk add --no-cache bash curl jq openssl coreutils >/dev/null

candidate=$(mktemp "${TMPDIR:-/tmp}/sbctl-bootstrap.XXXXXX")
trap 'rm -f "$candidate"' EXIT INT TERM
curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 60 "$DIST_URL" -o "$candidate" \
  || { echo '[sbctl] sbctl 发行版下载失败。' >&2; exit 1; }
grep -Fq '# Built from modular sources by scripts/build.sh.' "$candidate" \
  || { echo '[sbctl] 下载内容不是有效的 sbctl 发行版。' >&2; exit 1; }
bash -n "$candidate" || { echo '[sbctl] sbctl 发行版语法校验失败。' >&2; exit 1; }

mkdir -p /usr/local/sbin /usr/local/bin
cp "$candidate" "$TARGET"
chmod 755 "$TARGET"
ln -sfn "$TARGET" "$SYMLINK"
exec bash "$TARGET" install
