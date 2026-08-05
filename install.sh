#!/usr/bin/env bash
# Bootstrap installer for QiuXiaoye1112/sbctl.
set -Eeuo pipefail
readonly REPO="QiuXiaoye1112/sbctl"
readonly TARGET="/usr/local/sbin/sbctl"
readonly LIB_DIR="/usr/local/lib/sbctl"
readonly MODULES="core certmeta ui engine compat inbound certificate reality outbound clients share ops certops management uninstall menu protocols layout hy2_hop hy2_create hy2_nft enhancements cloudflare hardening"
info() { printf '[sbctl] %s\n' "$*"; }
die() { printf '[sbctl] 错误: %s\n' "$*" >&2; exit 1; }
fetch() { curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 60 "$1" -o "$2"; }
[[ $(uname -s) == Linux ]] || die "仅支持 Linux。"
[[ $(id -u) -eq 0 ]] || die "请使用 root 运行。"
command -v curl >/dev/null 2>&1 || die "缺少 curl。"
command -v install >/dev/null 2>&1 || die "缺少 install。"
command -v bash >/dev/null 2>&1 || die "缺少 bash。"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/sbctl-bootstrap.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
commit=""
if meta=$(curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --connect-timeout 8 --max-time 20 \
  -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/${REPO}/commits/main" 2>/dev/null); then
  commit=$(printf '%s' "$meta" | sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | sed -n '1p')
fi
if [[ $commit =~ ^[0-9a-f]{40}$ ]]; then
  BASE_URL="https://raw.githubusercontent.com/${REPO}/${commit}"
  info "锁定源码提交：${commit:0:12}"
else
  BASE_URL="https://github.com/${REPO}/raw/refs/heads/main"
  warn=''
  info "无法解析 main 提交，使用 GitHub 实时分支下载。"
fi
info "正在下载并校验 sbctl..."
fetch "$BASE_URL/sbctl.sh" "$tmp/sbctl.sh" || die "主脚本下载失败。"
grep -q '^# sbctl - sing-box Linux terminal manager' "$tmp/sbctl.sh" || die "主脚本内容校验失败。"
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
rm -f "$LIB_DIR/system_ext.sh"
ln -sfn "$TARGET" /usr/local/bin/sbctl
info "正在安装/修复 sing-box..."
SBCTL_LIB_DIR="$LIB_DIR" "$TARGET" install "${1-}"
info "完成。运行 sbctl 打开管理菜单。"
