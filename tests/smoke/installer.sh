#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

CASE_DIR=$(mktemp -d)
trap 'rm -rf "$CASE_DIR"' EXIT
mkdir -p "$CASE_DIR/bin" "$CASE_DIR/source"

printf '%s\n' '#!/usr/bin/env bash' '# Built from modular sources by scripts/build.sh.' \
  'printf "%s\n" "$*" >"$SBCTL_INSTALL_TEST_LOG"' >"$CASE_DIR/source/sbctl"
chmod +x "$CASE_DIR/source/sbctl"

cat >"$CASE_DIR/bin/uname" <<'SH'
#!/usr/bin/env sh
printf 'Linux\n'
SH
cat >"$CASE_DIR/bin/id" <<'SH'
#!/usr/bin/env sh
printf '0\n'
SH
cat >"$CASE_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
while (($#)); do
  if [[ $1 == -o ]]; then cp "$SBCTL_INSTALL_TEST_SOURCE" "$2"; exit 0; fi
  shift
done
exit 1
SH
chmod +x "$CASE_DIR/bin/"*

PATH="$CASE_DIR/bin:$PATH" \
SBCTL_DIST_URL=https://example.invalid/dist/sbctl \
SBCTL_INSTALL_TARGET="$CASE_DIR/install/sbin/sbctl" \
SBCTL_INSTALL_SYMLINK="$CASE_DIR/install/bin/sbctl" \
SBCTL_INSTALL_TEST_SOURCE="$CASE_DIR/source/sbctl" \
SBCTL_INSTALL_TEST_LOG="$CASE_DIR/install.log" \
bash ./install.sh 1.2.3 >/dev/null

[[ -x $CASE_DIR/install/sbin/sbctl ]]
[[ -L $CASE_DIR/install/bin/sbctl ]]
[[ $(<"$CASE_DIR/install.log") == 'install 1.2.3' ]]

export PATH="$CASE_DIR/bin:$PATH"
export SBCTL_DIST_URL=https://example.invalid/dist/sbctl
export SBCTL_INSTALL_TARGET="$CASE_DIR/install/sbin/sbctl"
export SBCTL_INSTALL_SYMLINK="$CASE_DIR/install/bin/sbctl"
export SBCTL_INSTALL_TEST_SOURCE="$CASE_DIR/source/sbctl"
export SBCTL_INSTALL_TEST_LOG="$CASE_DIR/install.log"
printf 'existing core\n' >"$CASE_DIR/core"
printf 'existing config\n' >"$CASE_DIR/config"
printf 'untouched\n' >"$SBCTL_INSTALL_TEST_LOG"
bash ./install.sh >"$CASE_DIR/update.out"
[[ $(<"$SBCTL_INSTALL_TEST_LOG") == untouched ]]
[[ $(<"$CASE_DIR/core") == 'existing core' && $(<"$CASE_DIR/config") == 'existing config' ]]
grep -Fq '管理脚本已更新' "$CASE_DIR/update.out"
bash ./install.sh 1.2.3 >/dev/null
[[ $(<"$SBCTL_INSTALL_TEST_LOG") == 'install 1.2.3' ]]

# Exercise the Alpine shell entry point without depending on the host OS.
sed 's@\[ -f /etc/alpine-release \]@[ -f "$SBCTL_TEST_ALPINE_RELEASE" ]@' alpine/install.sh >"$CASE_DIR/alpine-install.sh"
touch "$CASE_DIR/alpine-release"
export SBCTL_TEST_ALPINE_RELEASE="$CASE_DIR/alpine-release"
export SBCTL_INSTALL_TARGET="$CASE_DIR/alpine/sbin/sbctl"
export SBCTL_INSTALL_SYMLINK="$CASE_DIR/alpine/bin/sbctl"
cat >"$CASE_DIR/bin/apk" <<'SH'
#!/usr/bin/env sh
printf 'apk called\n' >>"$SBCTL_INSTALL_TEST_APK_LOG"
SH
chmod +x "$CASE_DIR/bin/apk"
export SBCTL_INSTALL_TEST_APK_LOG="$CASE_DIR/apk.log"
sh "$CASE_DIR/alpine-install.sh" >/dev/null
[[ $(<"$SBCTL_INSTALL_TEST_LOG") == 'install ' || $(<"$SBCTL_INSTALL_TEST_LOG") == 'install' ]]
printf 'untouched\n' >"$SBCTL_INSTALL_TEST_LOG"
sh "$CASE_DIR/alpine-install.sh" >"$CASE_DIR/alpine-update.out"
[[ $(<"$SBCTL_INSTALL_TEST_LOG") == untouched ]]
grep -Fq '管理脚本已更新' "$CASE_DIR/alpine-update.out"
sh "$CASE_DIR/alpine-install.sh" 1.2.3 >/dev/null
[[ $(<"$SBCTL_INSTALL_TEST_LOG") == 'install 1.2.3' ]]

printf 'installer smoke checks passed.\n'
