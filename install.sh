#!/usr/bin/env bash
# Bootstrap installer for QiuXiaoye1112/sbctl.
set -Eeuo pipefail

readonly REPO="QiuXiaoye1112/sbctl"
readonly TARGET="${SBCTL_INSTALL_TARGET:-/usr/local/sbin/sbctl}"
readonly SYMLINK="${SBCTL_INSTALL_SYMLINK:-/usr/local/bin/sbctl}"
readonly DIST_URL="${SBCTL_DIST_URL:-https://raw.githubusercontent.com/${REPO}/refs/heads/main/dist/sbctl}"

info() { printf '[sbctl] %s\n' "$*"; }
die() { printf '[sbctl] 错误: %s\n' "$*" >&2; exit 1; }
fetch() { curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 60 "$1" -o "$2"; }

[[ $(uname -s) == Linux ]] || die "仅支持 Linux。"
[[ $(id -u) -eq 0 ]] || die "请使用 root 运行。"
for dependency in curl install bash; do command -v "$dependency" >/dev/null 2>&1 || die "缺少 ${dependency}。"; done

bootstrap_tmp_dir() {
  local base=${SBCTL_TMP_DIR:-/var/tmp}
  mkdir -p "$base" && mktemp "$base/sbctl-bootstrap.XXXXXX"
}

candidate=$(bootstrap_tmp_dir) || die "无法创建引导安装临时文件。"
trap 'rm -f "$candidate"' EXIT
fetch "$DIST_URL" "$candidate" || die "sbctl 发行版下载失败。"
grep -Fq '# Built from modular sources by scripts/build.sh.' "$candidate" || die "下载内容不是有效的 sbctl 发行版。"
bash -n "$candidate" || die "sbctl 发行版语法校验失败。"

install -d -m 755 "$(dirname "$TARGET")" "$(dirname "$SYMLINK")"
install -m 755 "$candidate" "$TARGET"
ln -sfn "$TARGET" "$SYMLINK"
info "正在安装/修复 sing-box..."
"$TARGET" install "${1-}"
info "完成。运行 sbctl 打开管理菜单。"
