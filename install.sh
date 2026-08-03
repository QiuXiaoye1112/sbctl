#!/usr/bin/env bash
# Bootstrap installer for QiuXiaoye1112/sbctl.
set -Eeuo pipefail

readonly SCRIPT_URL="https://raw.githubusercontent.com/QiuXiaoye1112/sbctl/main/sbctl.sh"
readonly TARGET="/usr/local/sbin/sbctl"

info() { printf '[sbctl] %s\n' "$*"; }
die() { printf '[sbctl] 错误: %s\n' "$*" >&2; exit 1; }

[[ $(uname -s) == Linux ]] || die "仅支持 Linux。"
[[ $(id -u) -eq 0 ]] || die "请使用 root 运行。"
command -v curl >/dev/null 2>&1 || die "缺少 curl。"
command -v install >/dev/null 2>&1 || die "缺少 install。"

temp=$(mktemp "${TMPDIR:-/tmp}/sbctl-bootstrap.XXXXXX")
trap 'rm -f "$temp"' EXIT

info "正在下载 sbctl..."
curl -fsSL --proto '=https' --tlsv1.2 --retry 3 "$SCRIPT_URL" -o "$temp"
grep -q '^# sbctl - sing-box Linux terminal manager' "$temp" || die "下载内容校验失败。"
install -m 755 "$temp" "$TARGET"
ln -sfn "$TARGET" /usr/local/bin/sbctl

info "正在安装/修复 sing-box..."
"$TARGET" install "${1-}"
info "完成。运行 sbctl 打开管理菜单。"
