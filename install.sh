#!/usr/bin/env bash
# Bootstrap installer for QiuXiaoye1112/sbctl.
set -Eeuo pipefail

readonly REPO="QiuXiaoye1112/sbctl"
readonly TARGET="${SBCTL_INSTALL_TARGET:-/usr/local/sbin/sbctl}"
readonly SYMLINK="${SBCTL_INSTALL_SYMLINK:-/usr/local/bin/sbctl}"
readonly DIST_URL="${SBCTL_DIST_URL:-https://raw.githubusercontent.com/${REPO}/refs/heads/main/dist/sbctl}"

info() { printf '[sbctl] %s\n' "$*"; }
die() { printf '[sbctl] 错误: %s\n' "$*" >&2; exit 1; }
fetch() {
  local url=$1 separator='?'
  [[ $url == *\?* ]] && separator='&'
  # Raw/CDN may serve an older immutable-looking main-branch object; use a
  # per-run query parameter so the README installer always obtains current code.
  url="${url}${separator}sbctl_cache=$(date +%s)"
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 60 "$url" -o "$2"
}

[[ $(uname -s) == Linux ]] || die "仅支持 Linux。"
[[ $(id -u) -eq 0 ]] || die "请使用 root 运行。"
for dependency in curl install bash; do command -v "$dependency" >/dev/null 2>&1 || die "缺少 ${dependency}。"; done

bootstrap_tmp_dir() {
  local base=${SBCTL_TMP_DIR:-/var/tmp}
  mkdir -p "$base" && mktemp "$base/sbctl-bootstrap.XXXXXX"
}

candidate=$(bootstrap_tmp_dir) || die "无法创建引导安装临时文件。"
staged=""
cleanup() { rm -f "$candidate"; [[ -z $staged ]] || rm -f "$staged"; }
trap cleanup EXIT
fetch "$DIST_URL" "$candidate" || die "sbctl 发行版下载失败。"
grep -Fq '# Built from modular sources by scripts/build.sh.' "$candidate" || die "下载内容不是有效的 sbctl 发行版。"
bash -n "$candidate" || die "sbctl 发行版语法校验失败。"

[[ ! -L $TARGET ]] || die "目标路径是符号链接：$TARGET"
if [[ -e $TARGET ]] && ! grep -Fq '# Built from modular sources by scripts/build.sh.' "$TARGET"; then
  die "目标路径已存在且不是 sbctl：$TARGET"
fi
if [[ -e $SYMLINK && ! -L $SYMLINK && ! $SYMLINK -ef $TARGET ]]; then
  die "快捷命令路径已被其他文件占用：$SYMLINK"
fi
mode=install
if [[ $# -eq 0 && -f $TARGET ]]; then mode=update; fi
install -d -m 755 "$(dirname "$TARGET")" "$(dirname "$SYMLINK")"
staged=$(mktemp "${TARGET}.tmp.XXXXXX")
install -m 755 "$candidate" "$staged"
mv -f "$staged" "$TARGET"
staged=""
ln -sfn "$TARGET" "$SYMLINK"
if [[ $mode == update ]]; then
  info "sbctl 管理脚本已更新。"
else
  info "正在安装/修复 sing-box..."
  SBCTL_COMMAND_PATH="$TARGET" SBCTL_SYMLINK_PATH="$SYMLINK" "$TARGET" install "${1-}"
  info "安装完成。运行 sbctl 打开管理菜单。"
fi
