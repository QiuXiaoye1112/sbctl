#!/usr/bin/env sh
set -eu
BASE_URL="https://raw.githubusercontent.com/QiuXiaoye1112/sbctl/main"
TARGET="/usr/local/sbin/sbctl"
LIB_DIR="/usr/local/lib/sbctl"
[ "$(id -u)" -eq 0 ] || { echo '[sbctl] 请使用 root 运行。' >&2; exit 1; }
[ -f /etc/alpine-release ] || { echo '[sbctl] 此入口仅用于 Alpine Linux。' >&2; exit 1; }
apk add --no-cache bash curl jq openssl sing-box
mkdir -p /usr/local/sbin /usr/local/bin "$LIB_DIR"
curl -fsSL "$BASE_URL/sbctl.sh" -o "$TARGET"
grep -q '^# sbctl - sing-box Linux terminal manager' "$TARGET" || { rm -f "$TARGET"; echo '[sbctl] 下载内容校验失败。' >&2; exit 1; }
for module in core certmeta ui engine compat inbound certificate reality outbound clients share ops certops management uninstall menu protocols layout hy2_hop hy2_create hy2_nft enhancements; do
  curl -fsSL "$BASE_URL/lib/${module}.sh" -o "$LIB_DIR/${module}.sh"
  [ -s "$LIB_DIR/${module}.sh" ] || { echo "[sbctl] 模块下载失败: $module" >&2; exit 1; }
done
rm -f "$LIB_DIR/system_ext.sh"
chmod 755 "$TARGET"
chmod 644 "$LIB_DIR"/*.sh
ln -sfn "$TARGET" /usr/local/bin/sbctl
exec env SBCTL_LIB_DIR="$LIB_DIR" bash "$TARGET" install
