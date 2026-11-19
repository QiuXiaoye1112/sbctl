#!/usr/bin/env sh
set -eu

REPO="QiuXiaoye1112/sbctl"
TARGET="${SBCTL_INSTALL_TARGET:-/usr/local/sbin/sbctl}"
SYMLINK="${SBCTL_INSTALL_SYMLINK:-/usr/local/bin/sbctl}"
DIST_URL="${SBCTL_DIST_URL:-https://raw.githubusercontent.com/${REPO}/refs/heads/main/dist/sbctl}"

[ "$(id -u)" -eq 0 ] || { echo '[sbctl] 请使用 root 运行。' >&2; exit 1; }
[ -f /etc/alpine-release ] || { echo '[sbctl] 此入口仅用于 Alpine Linux。' >&2; exit 1; }
missing=""
for dependency in bash curl jq openssl install; do
  command -v "$dependency" >/dev/null 2>&1 || missing=1
done
[ -z "$missing" ] || apk add --no-cache bash curl jq openssl coreutils iproute2 >/dev/null

candidate=$(mktemp "${TMPDIR:-/tmp}/sbctl-bootstrap.XXXXXX")
staged=""
cleanup() { rm -f "$candidate"; [ -z "$staged" ] || rm -f "$staged"; }
trap cleanup EXIT INT TERM
curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 60 "$DIST_URL" -o "$candidate" \
  || { echo '[sbctl] sbctl 发行版下载失败。' >&2; exit 1; }
grep -Fq '# Built from modular sources by scripts/build.sh.' "$candidate" \
  || { echo '[sbctl] 下载内容不是有效的 sbctl 发行版。' >&2; exit 1; }
bash -n "$candidate" || { echo '[sbctl] sbctl 发行版语法校验失败。' >&2; exit 1; }

[ ! -L "$TARGET" ] || { echo "[sbctl] 目标路径是符号链接：$TARGET" >&2; exit 1; }
if [ -e "$TARGET" ] && ! grep -Fq '# Built from modular sources by scripts/build.sh.' "$TARGET"; then
  echo "[sbctl] 目标路径已存在且不是 sbctl：$TARGET" >&2; exit 1
fi
if [ -e "$SYMLINK" ] && [ ! -L "$SYMLINK" ] && [ "$SYMLINK" != "$TARGET" ]; then
  echo "[sbctl] 快捷命令路径已被其他文件占用：$SYMLINK" >&2; exit 1
fi
mode=install
if [ "$#" -eq 0 ] && [ -f "$TARGET" ]; then mode=update; fi
mkdir -p "$(dirname "$TARGET")" "$(dirname "$SYMLINK")"
staged=$(mktemp "${TARGET}.tmp.XXXXXX")
install -m 755 "$candidate" "$staged"
mv -f "$staged" "$TARGET"
staged=""
ln -sfn "$TARGET" "$SYMLINK"
if [ "$mode" = update ]; then
  echo '[sbctl] sbctl 管理脚本已更新。'
else
  SBCTL_COMMAND_PATH="$TARGET" SBCTL_SYMLINK_PATH="$SYMLINK" bash "$TARGET" install "${1-}"
fi
