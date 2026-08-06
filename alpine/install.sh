#!/usr/bin/env sh
set -eu
REPO="QiuXiaoye1112/sbctl"
TARGET="/usr/local/sbin/sbctl"
LIB_DIR="/usr/local/lib/sbctl"
MODULES="cache core ui engine compat certmeta inbound certificate reality outbound clients share ops certops cloudflare hy2_hop hy2_create hy2_nft network_guard protocols system_guard menu uninstall"
[ "$(id -u)" -eq 0 ] || { echo '[sbctl] 请使用 root 运行。' >&2; exit 1; }
[ -f /etc/alpine-release ] || { echo '[sbctl] 此入口仅用于 Alpine Linux。' >&2; exit 1; }
apk add --no-cache bash curl jq openssl coreutils >/dev/null
tmp=$(mktemp -d "${TMPDIR:-/tmp}/sbctl-bootstrap.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM
commit=""
meta=$(curl -fsSL --retry 2 --connect-timeout 8 --max-time 20 \
  -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/${REPO}/commits/main" 2>/dev/null || true)
commit=$(printf '%s' "$meta" | sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | sed -n '1p')
case "$commit" in
  ????????????????????????????????????????) BASE_URL="https://raw.githubusercontent.com/${REPO}/${commit}"; echo "[sbctl] 锁定源码提交：$(printf '%.12s' "$commit")" ;;
  *) BASE_URL="https://github.com/${REPO}/raw/refs/heads/main"; echo '[sbctl] 无法解析 main 提交，使用 GitHub 实时分支下载。' ;;
esac
fetch() { curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 60 "$1" -o "$2"; }
echo '[sbctl] 正在下载并校验 sbctl...'
fetch "$BASE_URL/sbctl.sh" "$tmp/sbctl.sh" || { echo '[sbctl] 主脚本下载失败。' >&2; exit 1; }
grep -q '^# sbctl - sing-box Linux terminal manager' "$tmp/sbctl.sh" || { echo '[sbctl] 主脚本内容校验失败。' >&2; exit 1; }
mkdir -p "$tmp/lib"
for module in $MODULES; do
  fetch "$BASE_URL/lib/${module}.sh" "$tmp/lib/${module}.sh" || { echo "[sbctl] 模块下载失败: $module" >&2; exit 1; }
  [ -s "$tmp/lib/${module}.sh" ] || { echo "[sbctl] 模块为空: $module" >&2; exit 1; }
done
bash -n "$tmp/sbctl.sh" || { echo '[sbctl] 主脚本语法校验失败。' >&2; exit 1; }
for module in $MODULES; do bash -n "$tmp/lib/${module}.sh" || { echo "[sbctl] 模块语法校验失败: $module" >&2; exit 1; }; done
mkdir -p /usr/local/sbin /usr/local/bin "$LIB_DIR"
cp "$tmp/lib/"*.sh "$LIB_DIR/"
chmod 644 "$LIB_DIR"/*.sh
cp "$tmp/sbctl.sh" "$TARGET"
chmod 755 "$TARGET"
rm -f "$LIB_DIR/system_ext.sh" "$LIB_DIR/hardening.sh"
ln -sfn "$TARGET" /usr/local/bin/sbctl
exec env SBCTL_LIB_DIR="$LIB_DIR" bash "$TARGET" install
