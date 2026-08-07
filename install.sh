#!/usr/bin/env bash
# Bootstrap installer for QiuXiaoye1112/sbctl.
set -Eeuo pipefail
readonly REPO="QiuXiaoye1112/sbctl"
readonly TARGET="/usr/local/sbin/sbctl"
readonly LIB_DIR="/usr/local/lib/sbctl"
readonly MODULES="cache core ui engine compat certmeta inbound certificate reality outbound clients share ops certops cloudflare cert_guard hy2_hop hy2_create hy2_nft network_guard protocols system_guard management menu uninstall"
info() { printf '[sbctl] %s\n' "$*"; }
die() { printf '[sbctl] 错误: %s\n' "$*" >&2; exit 1; }
fetch() { curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 60 "$1" -o "$2"; }
[[ $(uname -s) == Linux ]] || die "仅支持 Linux。"
[[ $(id -u) -eq 0 ]] || die "请使用 root 运行。"
command -v curl >/dev/null 2>&1 || die "缺少 curl。"
command -v install >/dev/null 2>&1 || die "缺少 install。"
command -v bash >/dev/null 2>&1 || die "缺少 bash。"
# Clear any stale lock from previous interrupted runs
rm -rf /run/lock/sbctl.lock /run/lock/sbctl.lock.d 2>/dev/null || true
tmp=$(mktemp -d "${TMPDIR:-/tmp}/sbctl-bootstrap.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
BASE_URL="https://raw.githubusercontent.com/${REPO}/refs/heads/main"
fetch "$BASE_URL/sbctl.sh" "$tmp/sbctl.sh" || die "主脚本下载失败。"
mkdir -p "$tmp/lib"
for module in $MODULES; do
  fetch "$BASE_URL/lib/${module}.sh" "$tmp/lib/${module}.sh" || die "模块下载失败：${module}"
  [[ -s "$tmp/lib/${module}.sh" ]] || die "模块为空：${module}"
done
bash -n "$tmp/sbctl.sh" || die "主脚本语法校验失败。"
for module in $MODULES; do bash -n "$tmp/lib/${module}.sh" || die "模块语法校验失败：${module}"; done
install -d -m 755 "$LIB_DIR" /usr/local/sbin /usr/local/bin
install -m 644 "$tmp/lib/"*.sh "$LIB_DIR/"
install -m 755 "$tmp/sbctl.sh" "$TARGET"
rm -f "$LIB_DIR/system_ext.sh" "$LIB_DIR/hardening.sh"
ln -sfn "$TARGET" /usr/local/bin/sbctl
info "正在安装/修复 sing-box..."
SBCTL_LIB_DIR="$LIB_DIR" "$TARGET" install "${1-}"
info "完成。运行 sbctl 打开管理菜单。"
