#!/usr/bin/env bash
# Bootstrap installer for QiuXiaoye1112/sbctl.
set -Eeuo pipefail
readonly BASE_URL="https://raw.githubusercontent.com/QiuXiaoye1112/sbctl/main"
readonly TARGET="/usr/local/sbin/sbctl"
readonly LIB_DIR="/usr/local/lib/sbctl"
info() { printf '[sbctl] %s\n' "$*"; }
die() { printf '[sbctl] 错误: %s\n' "$*" >&2; exit 1; }
[[ $(uname -s) == Linux ]] || die "仅支持 Linux。"
[[ $(id -u) -eq 0 ]] || die "请使用 root 运行。"
command -v curl >/dev/null 2>&1 || die "缺少 curl。"
command -v install >/dev/null 2>&1 || die "缺少 install。"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/sbctl-bootstrap.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
info "正在下载 sbctl..."
curl -fsSL --proto '=https' --tlsv1.2 --retry 3 "$BASE_URL/sbctl.sh" -o "$tmp/sbctl.sh"
grep -q '^# sbctl - sing-box Linux terminal manager' "$tmp/sbctl.sh" || die "下载内容校验失败。"
mkdir -p "$tmp/lib"
for module in core ui engine compat inbound certificate reality outbound clients share ops management menu protocols layout hy2_hop hy2_create hy2_nft hy2_interval; do
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 "$BASE_URL/lib/${module}.sh" -o "$tmp/lib/${module}.sh"
  [[ -s "$tmp/lib/${module}.sh" ]] || die "模块下载失败：${module}"
done
install -d -m 755 "$LIB_DIR"
rm -f "$LIB_DIR/system_ext.sh"
install -m 644 "$tmp/lib/"*.sh "$LIB_DIR/"
install -m 755 "$tmp/sbctl.sh" "$TARGET"
ln -sfn "$TARGET" /usr/local/bin/sbctl
info "正在安装/修复 sing-box..."
SBCTL_LIB_DIR="$LIB_DIR" "$TARGET" install "${1-}"
info "完成。运行 sbctl 打开管理菜单。"
