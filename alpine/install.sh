#!/usr/bin/env sh
set -eu

SCRIPT_URL="https://raw.githubusercontent.com/QiuXiaoye1112/sbctl/main/sbctl.sh"
TARGET="/usr/local/sbin/sbctl"

[ "$(id -u)" -eq 0 ] || { echo '[sbctl] 请使用 root 运行。' >&2; exit 1; }
[ -f /etc/alpine-release ] || { echo '[sbctl] 此入口仅用于 Alpine Linux。' >&2; exit 1; }

apk add --no-cache bash curl jq openssl sing-box
mkdir -p /usr/local/sbin /usr/local/bin
curl -fsSL "$SCRIPT_URL" -o "$TARGET"
grep -q '^# sbctl - sing-box Linux terminal manager' "$TARGET" || { rm -f "$TARGET"; echo '[sbctl] 下载内容校验失败。' >&2; exit 1; }
chmod 755 "$TARGET"
ln -sfn "$TARGET" /usr/local/bin/sbctl
exec bash "$TARGET" install
