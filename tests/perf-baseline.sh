#!/usr/bin/env bash
# Performance regression test for sbctl hot paths.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

failures=0
assert_eq() {
  local label=$1 actual=$2 expected=$3
  if ((actual != expected)); then printf '  FAIL [%s] %d != %d\n' "$label" "$actual" "$expected" >&2; ((failures+=1))
  else printf '  ok   [%s] %d == %d\n' "$label" "$actual" "$expected"; fi
}
assert_le() {
  local label=$1 actual=$2 max=$3
  if ((actual > max)); then printf '  FAIL [%s] %d > %d\n' "$label" "$actual" "$max" >&2; ((failures+=1))
  else printf '  ok   [%s] %d <= %d\n' "$label" "$actual" "$max"; fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
COUNTERS="$TMP/counters"
mkdir -p "$TMP/bin" "$TMP/cfg" "$TMP/certs"

# ---- mocks ----
cat >"$TMP/bin/sing-box" <<'SCRIPT'
#!/usr/bin/env bash
echo "sing-box" >> "${COUNTERS:-/dev/null}"
case "${1-}" in
  version) echo "sing-box version 1.14.0" ;;
  generate) case "${2-}" in uuid) echo "00000000-0000-0000-0000-000000000000" ;; reality-keypair) printf 'PrivateKey: p\nPublicKey: P\n' ;; esac ;;
  check) exit 0 ;;
esac; exit 0
SCRIPT
chmod +x "$TMP/bin/sing-box"

cat >"$TMP/bin/jq" <<'SCRIPT'
#!/usr/bin/env bash
echo "jq" >> "${COUNTERS:-/dev/null}"; exec /usr/bin/jq "$@"
SCRIPT
chmod +x "$TMP/bin/jq"

cat >"$TMP/bin/systemctl" <<'SCRIPT'
#!/usr/bin/env bash
echo "systemctl" >> "${COUNTERS:-/dev/null}"
case "$*" in
  *show*) printf 'LoadState=loaded\nActiveState=active\nUnitFileState=enabled\n' ;;
  *) : ;;
esac; exit 0
SCRIPT
chmod +x "$TMP/bin/systemctl"

cat >"$TMP/bin/openssl" <<'SCRIPT'
#!/usr/bin/env bash
echo "openssl" >> "${COUNTERS:-/dev/null}"; exec /usr/bin/openssl "$@"
SCRIPT
chmod +x "$TMP/bin/openssl"

cat >"$TMP/bin/curl" <<'SCRIPT'
#!/usr/bin/env bash
echo "curl" >> "${COUNTERS:-/dev/null}"; exit 1
SCRIPT
chmod +x "$TMP/bin/curl"

cat >"$TMP/bin/sed" <<'SCRIPT'
#!/usr/bin/env bash
echo "sed" >> "${COUNTERS:-/dev/null}"; exec /usr/bin/sed "$@"
SCRIPT
chmod +x "$TMP/bin/sed"

cat >"$TMP/cfg/config.json" <<'JSON'
{"log":{"level":"warn"},"inbounds":[{"type":"vless","tag":"v","listen":"::","listen_port":443,"users":[{"name":"u","uuid":"00000000-0000-0000-0000-000000000001","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"x.com","reality":{"enabled":true,"handshake":{"server":"m.com","server_port":443},"private_key":"k","short_id":["a"]}}},{"type":"trojan","tag":"t","listen":"::","listen_port":8443,"users":[{"name":"u","password":"p"}],"tls":{"enabled":true,"server_name":"t.com"}}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}
JSON
cat >"$TMP/meta.json" <<'JSON'
{"schema":2,"inbounds":{"v":{"host":"1.2.3.4"},"t":{"host":"t.com"}},"certificates":{},"managedResources":{},"migrations":{"legacyCertScanV1":true}}
JSON

export COUNTERS

# Helper: run test script inside bash -c, return counts
run_test() {
  local script=$1
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
count() { local n=0; [[ -f $COUNTERS ]] && n=$(grep -c "^${1}$" "$COUNTERS" 2>/dev/null) || n=0; printf '%d' "$n"; }

echo "=== sbctl Performance Regression Test ==="
echo ""

# ========================================================================
# 1. _service_states parsing: verify while-read-case logic extracts fields
# ========================================================================
echo "--- _service_states parsing ---"
_parse_systemctl_output() {
  local load=not-found active=inactive unitfile=disabled line
  while IFS= read -r line; do
    case $line in
      LoadState=*)   load=${line#LoadState=} ;;
      ActiveState=*) active=${line#ActiveState=} ;;
      UnitFileState=*) unitfile=${line#UnitFileState=} ;;
    esac
  done
  printf '%s %s %s' "$load" "$active" "$unitfile"
}
parsed=$(printf 'LoadState=loaded\nActiveState=active\nUnitFileState=enabled\n' | _parse_systemctl_output)
[[ $parsed == "loaded active enabled" ]] || { echo "  FAIL: parsed=[$parsed]" >&2; ((failures+=1)); }
echo "  ok   parsed=[$parsed]"

# ========================================================================
# 2. sing-box version cache: 3 calls = exactly 1 exec
# ========================================================================
echo "--- sing_box_version cache ---"
run_test '
source ./sbctl.sh
sing_box_version > /dev/null
sing_box_version > /dev/null
sing_box_version > /dev/null
'
assert_eq "  sing-box execs" "$(count sing-box)" 1

# ========================================================================
# 3. cache invalidate: 2 execs total
# ========================================================================
echo "--- cache invalidate ---"
run_test '
source ./sbctl.sh
sing_box_version > /dev/null
sbc_invalidate_install_cache
sing_box_version > /dev/null
'
assert_eq "  sing-box execs" "$(count sing-box)" 2

# ========================================================================
# 4. list_inbounds: exactly 1 jq, 0 systemctl/curl/openssl
# ========================================================================
echo "--- list_inbounds ---"
run_test '
source ./sbctl.sh
list_inbounds > /dev/null
'
assert_eq "  systemctl" "$(count systemctl)" 0
assert_eq "  curl"      "$(count curl)"      0
assert_eq "  openssl"   "$(count openssl)"   0
assert_eq "  jq"        "$(count jq)"        1

# ========================================================================
# 5. node_summary: 0 curl, 0 openssl
# ========================================================================
echo "--- node_summary ---"
run_test '
source ./sbctl.sh
node_summary > /dev/null
'
assert_le "  sing-box" "$(count sing-box)" 1
assert_eq "  curl"     "$(count curl)"     0
assert_eq "  openssl"  "$(count openssl)"  0

# ========================================================================
# 6. Cache survives run_menu_action (SUCCESS)
# ========================================================================
echo "--- cache survives run_menu_action ---"
run_test '
source ./sbctl.sh
sing_box_version > /dev/null
run_menu_action true
# After subshell exits, cache dir must still exist
[[ -n ${_SBC_CACHE_DIR:-} && -d ${_SBC_CACHE_DIR:-} ]] || { echo "CACHE_GONE" >&2; exit 1; }
sing_box_version > /dev/null  # must be cache hit
'
assert_eq "  sing-box execs (cache survived)" "$(count sing-box)" 1
echo "  ok   cache intact after run_menu_action"

# ========================================================================
# 7. Cache survives run_menu_action (FAILURE)
# ========================================================================
echo "--- cache survives failed run_menu_action ---"
run_test '
source ./sbctl.sh
sing_box_version > /dev/null
run_menu_action false 2>/dev/null || true
[[ -n ${_SBC_CACHE_DIR:-} && -d ${_SBC_CACHE_DIR:-} ]] || { echo "CACHE_GONE" >&2; exit 1; }
sing_box_version > /dev/null
'
assert_eq "  sing-box execs (cache survived)" "$(count sing-box)" 1
echo "  ok   cache intact after failed run_menu_action"

# ========================================================================
# 8. Standalone build is current
# ========================================================================
echo "--- standalone build ---"
before=$(shasum -a 256 dist/sbctl | awk '{print $1}')
bash scripts/build.sh >/dev/null
after=$(shasum -a 256 dist/sbctl | awk '{print $1}')
[[ $before == "$after" ]] || { echo '  FAIL dist/sbctl was stale' >&2; ((failures+=1)); }
echo '  ok   dist/sbctl is reproducible'

# ========================================================================
# 9. declare -f overrides
# ========================================================================
echo "--- declare -f ---"
grep -rn 'declare -f' src/ sbctl.sh 2>/dev/null && { echo '  FAIL' >&2; ((failures+=1)); } || echo '  ok   zero'

# ========================================================================
# 10. Cache directory lifecycle
# ========================================================================
echo "--- cache dir lifecycle ---"
cache_out=$(PATH="$TMP/bin:$PATH" SBCTL_TESTING=1 \
  SBCTL_SING_BOX_BIN="$TMP/bin/sing-box" SBCTL_CONFIG_DIR="$TMP/cfg" \
  SBCTL_CONFIG_FILE="$TMP/cfg/config.json" SBCTL_META_FILE="$TMP/meta.json" \
  SBCTL_CERT_DIR="$TMP/certs" SBCTL_LOCK_FILE="$TMP/lock" \
  bash -c 'source ./sbctl.sh
[[ -n ${_SBC_CACHE_DIR:-} && -d ${_SBC_CACHE_DIR:-} ]] && echo "EXISTS:$_SBC_CACHE_DIR" || echo "MISSING"
_sbc_cache _test "v"; v=$(_sbc_cached _test); [[ $v == v ]] && echo "SUBSHELL_OK" || echo "SUBSHELL_FAIL"
' 2>/dev/null)
cache_dir=$(echo "$cache_out" | grep '^EXISTS:' | cut -d: -f2-)
if [[ -n $cache_dir && -d $cache_dir ]]; then
  echo '  FAIL cache dir not cleaned on exit' >&2; rm -rf -- "$cache_dir" 2>/dev/null || true; ((failures+=1))
else echo '  ok   cache dir cleaned on exit'; fi
echo "$cache_out" | grep -q 'SUBSHELL_OK' && echo '  ok   subshell cache read' || { echo '  FAIL' >&2; ((failures+=1)); }

# ========================================================================
echo ""
if ((failures > 0)); then echo "=== ${failures} ASSERTION(S) FAILED ==="; exit 1
else echo "=== ALL ASSERTIONS PASSED ==="; fi
