#!/usr/bin/env bash
# Performance regression test for sbctl hot paths.
# Sources sbctl.sh, mocks external commands, asserts call-count limits.
# Must be runnable in CI (Linux with bash, jq, openssl available).
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

failures=0
assert_le() {
  local label=$1 actual=$2 max=$3
  if ((actual > max)); then
    printf '  FAIL [%s] %d > %d (max)\n' "$label" "$actual" "$max" >&2
    ((failures+=1))
  else
    printf '  ok   [%s] %d <= %d\n' "$label" "$actual" "$max"
  fi
}

# ---- test environment ----
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
COUNTERS="$TMP/counters"
mkdir -p "$TMP/bin" "$TMP/cfg" "$TMP/certs"

# Mock: sing-box
cat >"$TMP/bin/sing-box" <<'SCRIPT'
#!/usr/bin/env bash
echo "sing-box" >> "${COUNTERS:-/dev/null}"
case "${1-}" in
  version) echo "sing-box version 1.14.0" ;;
  generate)
    case "${2-}" in
      uuid) echo "00000000-0000-0000-0000-000000000000" ;;
      reality-keypair) printf 'PrivateKey: p\nPublicKey: P\n' ;;
    esac ;;
  check) exit 0 ;;
esac
exit 0
SCRIPT
chmod +x "$TMP/bin/sing-box"

# Mock: jq (pass-through to real jq for correctness)
cat >"$TMP/bin/jq" <<'SCRIPT'
#!/usr/bin/env bash
echo "jq" >> "${COUNTERS:-/dev/null}"
exec /usr/bin/jq "$@"
SCRIPT
chmod +x "$TMP/bin/jq"

# Mock: systemctl
cat >"$TMP/bin/systemctl" <<'SCRIPT'
#!/usr/bin/env bash
echo "systemctl" >> "${COUNTERS:-/dev/null}"
case "$*" in
  *show*|*LoadState*)
    printf 'LoadState=loaded\nActiveState=inactive\nUnitFileState=disabled\n'
    ;;
  *daemon-reload*) : ;;
  *) : ;;
esac
exit 0
SCRIPT
chmod +x "$TMP/bin/systemctl"

# Mock: openssl (pass-through)
cat >"$TMP/bin/openssl" <<'SCRIPT'
#!/usr/bin/env bash
echo "openssl" >> "${COUNTERS:-/dev/null}"
exec /usr/bin/openssl "$@"
SCRIPT
chmod +x "$TMP/bin/openssl"

# Mock: curl — must NEVER be called in hot path
cat >"$TMP/bin/curl" <<'SCRIPT'
#!/usr/bin/env bash
echo "curl" >> "${COUNTERS:-/dev/null}"
exit 1
SCRIPT
chmod +x "$TMP/bin/curl"

# Mock: sed (pass-through)
cat >"$TMP/bin/sed" <<'SCRIPT'
#!/usr/bin/env bash
echo "sed" >> "${COUNTERS:-/dev/null}"
exec /usr/bin/sed "$@"
SCRIPT
chmod +x "$TMP/bin/sed"

# Create config with 2 inbounds
cat >"$TMP/cfg/config.json" <<'JSON'
{"log":{"level":"warn","timestamp":true},"inbounds":[{"type":"vless","tag":"v","listen":"::","listen_port":443,"users":[{"name":"u","uuid":"00000000-0000-0000-0000-000000000001","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"x.com","reality":{"enabled":true,"handshake":{"server":"m.com","server_port":443},"private_key":"k","short_id":["a"]}}},{"type":"trojan","tag":"t","listen":"::","listen_port":8443,"users":[{"name":"u","password":"p"}],"tls":{"enabled":true,"server_name":"t.com"}}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}
JSON

cat >"$TMP/meta.json" <<'JSON'
{"schema":2,"inbounds":{"v":{"host":"1.2.3.4"},"t":{"host":"t.com"}},"certificates":{},"managedResources":{},"migrations":{"legacyCertScanV1":true}}
JSON

export COUNTERS

run_test() {
  local label=$1 script=$2
  > "$COUNTERS"
  COUNTERS="$COUNTERS" PATH="$TMP/bin:$PATH" \
  SBCTL_TESTING=1 \
  SBCTL_SING_BOX_BIN="$TMP/bin/sing-box" \
  SBCTL_CONFIG_DIR="$TMP/cfg" \
  SBCTL_CONFIG_FILE="$TMP/cfg/config.json" \
  SBCTL_META_FILE="$TMP/meta.json" \
  SBCTL_CERT_DIR="$TMP/certs" \
  SBCTL_LOCK_FILE="$TMP/lock" \
  bash -c "$script" 2>/dev/null
}

count() {
  local n=0
  if [[ -f $COUNTERS ]]; then
    n=$(grep -c "^${1}$" "$COUNTERS" 2>/dev/null) || n=0
  fi
  printf '%d' "$n"
}

echo "=== sbctl Performance Regression Test ==="
echo ""

# ---- 1. node_summary ----
run_test "node_summary" '
source ./sbctl.sh
node_summary > /dev/null
'
echo "  node_summary:"
assert_le "  systemctl" "$(count systemctl)" 1
assert_le "  sing-box"  "$(count sing-box)"  1
assert_le "  curl"      "$(count curl)"      0
assert_le "  openssl"   "$(count openssl)"   0

# ---- 2. service menu (_service_summary_all) ----
run_test "service_summary" '
source ./sbctl.sh
_service_summary_all > /dev/null
'
echo "  _service_summary_all:"
assert_le "  systemctl" "$(count systemctl)" 1

# ---- 3. sing-box version cache: 3 calls = 1 exec ----
run_test "version_cache" '
source ./sbctl.sh
sing_box_version > /dev/null
sing_box_version > /dev/null
sing_box_version > /dev/null
'
echo "  sing_box_version x3:"
assert_le "  sing-box (3 calls)" "$(count sing-box)" 1

# ---- 4. cache invalidate ----
run_test "cache_invalidate" '
source ./sbctl.sh
sing_box_version > /dev/null
sbc_invalidate_install_cache
sing_box_version > /dev/null
'
echo "  invalidate + re-query:"
assert_le "  sing-box (invalidate)" "$(count sing-box)" 2

# ---- 5. list_inbounds ----
run_test "list_inbounds" '
source ./sbctl.sh
list_inbounds > /dev/null
'
echo "  list_inbounds:"
assert_le "  systemctl" "$(count systemctl)" 0
assert_le "  curl"      "$(count curl)"      0
assert_le "  openssl"   "$(count openssl)"   0
assert_le "  jq"        "$(count jq)"        1

# ---- 6. init_system cached ----
run_test "init_system_cache" '
source ./sbctl.sh
init_system > /dev/null
init_system > /dev/null
init_system > /dev/null
'
echo "  init_system x3:"
assert_le "  sing-box" "$(count sing-box)" 0
assert_le "  curl"     "$(count curl)"     0

# ---- 7. MODULES sync ----
echo "  MODULES sync:"
sbctl_modules=$(grep '^for _module in ' sbctl.sh | sed 's/.*for _module in //' | sed 's/; do//')
install_modules=$(grep '^readonly MODULES=' install.sh | sed 's/readonly MODULES="//;s/"//')
alpine_modules=$(grep '^MODULES=' alpine/install.sh | sed 's/MODULES="//;s/"//')

if [[ "$sbctl_modules" == "$install_modules" ]]; then
  echo '  ok   sbctl.sh == install.sh'
else
  echo '  FAIL sbctl.sh != install.sh' >&2
  diff <(echo "$sbctl_modules" | tr ' ' '\n') <(echo "$install_modules" | tr ' ' '\n') >&2 || true
  ((failures+=1))
fi
if [[ "$sbctl_modules" == "$alpine_modules" ]]; then
  echo '  ok   sbctl.sh == alpine/install.sh'
else
  echo '  FAIL sbctl.sh != alpine/install.sh' >&2
  diff <(echo "$sbctl_modules" | tr ' ' '\n') <(echo "$alpine_modules" | tr ' ' '\n') >&2 || true
  ((failures+=1))
fi

# ---- 8. declare -f overrides ----
echo "  declare -f overrides:"
if grep -rn 'declare -f' lib/ sbctl.sh 2>/dev/null; then
  echo '  FAIL found declare -f overrides' >&2
  ((failures+=1))
else
  echo '  ok   zero'
fi

# ---- 9. Cache directory lifecycle ----
echo "  cache dir lifecycle:"
CACHE_TEST=$(
  PATH="$TMP/bin:$PATH" \
  SBCTL_TESTING=1 \
  SBCTL_SING_BOX_BIN="$TMP/bin/sing-box" \
  SBCTL_CONFIG_DIR="$TMP/cfg" \
  SBCTL_CONFIG_FILE="$TMP/cfg/config.json" \
  SBCTL_META_FILE="$TMP/meta.json" \
  SBCTL_CERT_DIR="$TMP/certs" \
  SBCTL_LOCK_FILE="$TMP/lock" \
  bash -c '
    source ./sbctl.sh
    # Cache dir exists after source
    if [[ -n ${_SBC_CACHE_DIR:-} && -d ${_SBC_CACHE_DIR:-} ]]; then
      echo "EXISTS:$_SBC_CACHE_DIR"
    else
      echo "MISSING"
    fi
    # Write test value
    _sbc_cache _test_key "test_value"
    # Read back — survives subshell
    v=$(_sbc_cached _test_key)
    [[ $v == test_value ]] && echo "SUBSHELL_OK" || echo "SUBSHELL_FAIL"
    # Parent can also read directly
    _sbc_cached _test_key > /dev/null && echo "PARENT_OK"
    # Exit the subshell — cleanup should happen
  ' 2>/dev/null
)
cache_dir=$(echo "$CACHE_TEST" | grep '^EXISTS:' | cut -d: -f2-)
echo "  cache dir: ${cache_dir:-MISSING}"
if [[ -n $cache_dir && -d $cache_dir ]]; then
  echo '  FAIL cache dir not cleaned on exit' >&2
  rm -rf -- "$cache_dir" 2>/dev/null || true
  ((failures+=1))
else
  echo '  ok   cache dir cleaned on exit'
fi
if echo "$CACHE_TEST" | grep -q 'SUBSHELL_OK'; then
  echo '  ok   subshell cache read'
else
  echo '  FAIL subshell cache read' >&2
  ((failures+=1))
fi

# ---- result ----
echo ""
if ((failures > 0)); then
  echo "=== ${failures} ASSERTION(S) FAILED ==="
  exit 1
else
  echo "=== ALL ASSERTIONS PASSED ==="
fi
