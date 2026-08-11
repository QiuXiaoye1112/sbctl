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

printf 'installer smoke checks passed.\n'
