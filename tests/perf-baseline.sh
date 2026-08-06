#!/usr/bin/env bash
# Performance baseline test for sbctl.
# Sources sbctl.sh, mocks external commands with counters, asserts max call counts.
# Fails hard if hot-path regressions are detected.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

# ---- helpers ----
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

# Mock sing-box with counter
cat >"$TMP/bin/sing-box" <<'SCRIPT'
#!/usr/bin/env bash
echo "sing-box" >> "${COUNTERS:-/tmp/sbctl-perf-counters}"
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

# Mock jq with counter — passes through to real jq for correctness
cat >"$TMP/bin/jq" <<'SCRIPT'
#!/usr/bin/env bash
echo "jq" >> "${COUNTERS:-/tmp/sbctl-perf-counters}"
exec /usr/bin/jq "$@"
SCRIPT
chmod +x "$TMP/bin/jq"

# Mock systemctl with counter
cat >"$TMP/bin/systemctl" <<'SCRIPT'
#!/usr/bin/env bash
echo "systemctl" >> "${COUNTERS:-/tmp/sbctl-perf-counters}"
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

# Mock openssl (pass through)
cat >"$TMP/bin/openssl" <<'SCRIPT'
#!/usr/bin/env bash
echo "openssl" >> "${COUNTERS:-/tmp/sbctl-perf-counters}"
exec /usr/bin/openssl "$@"
SCRIPT
chmod +x "$TMP/bin/openssl"

# Mock curl (never actually called in hot path)
cat >"$TMP/bin/curl" <<'SCRIPT'
#!/usr/bin/env bash
echo "curl" >> "${COUNTERS:-/tmp/sbctl-perf-counters}"
exit 1
SCRIPT
chmod +x "$TMP/bin/curl"

# Mock sed (pass through)
cat >"$TMP/bin/sed" <<'SCRIPT'
#!/usr/bin/env bash
echo "sed" >> "${COUNTERS:-/tmp/sbctl-perf-counters}"
exec /usr/bin/sed "$@"
SCRIPT
chmod +x "$TMP/bin/sed"

# Create minimal config and meta
cat >"$TMP/cfg/config.json" <<'JSON'
{
  "log": {"level": "warn", "timestamp": true},
  "inbounds": [
    {
      "type": "vless", "tag": "test-vless",
      "listen": "0.0.0.0", "listen_port": 443,
      "users": [{"name": "u1", "uuid": "00000000-0000-0000-0000-000000000001", "flow": "xtls-rprx-vision"}],
      "tls": {"enabled": true, "server_name": "example.com",
        "reality": {"enabled": true, "handshake": {"server": "www.microsoft.com", "server_port": 443},
        "private_key": "k", "short_id": ["abcd"]}}
    },
    {
      "type": "trojan", "tag": "test-trojan",
      "listen": "0.0.0.0", "listen_port": 8443,
      "users": [{"name": "t1", "password": "pass"}],
      "tls": {"enabled": true, "server_name": "t.example.com"}
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "route": {"final": "direct"}
}
JSON

cat >"$TMP/meta.json" <<'JSON'
{"schema":2,"inbounds":{"test-vless":{"host":"1.2.3.4","updatedAt":"2024-01-01T00:00:00Z"},"test-trojan":{"host":"t.example.com","updatedAt":"2024-01-01T00:00:00Z"}},"certificates":{},"managedResources":{},"migrations":{"legacyCertScanV1":true}}
JSON

# ---- actual test: source sbctl.sh and exercise hot paths ----
printf '=== sbctl Performance Baseline ===\n\n'

COUNTERS="$TMP/counters"
export COUNTERS

PATH="$TMP/bin:$PATH" \
SBCTL_TESTING=1 \
SBCTL_SING_BOX_BIN="$TMP/bin/sing-box" \
SBCTL_CONFIG_DIR="$TMP/cfg" \
SBCTL_CONFIG_FILE="$TMP/cfg/config.json" \
SBCTL_META_FILE="$TMP/meta.json" \
SBCTL_CERT_DIR="$TMP/certs" \
SBCTL_LOCK_FILE="$TMP/lock" \
bash -c '
set -Eeuo pipefail
source ./sbctl.sh

# ---- Phase 1: node_summary (main menu header) ----
echo "--- node_summary (main menu) ---"
> "$COUNTERS"
node_summary > /dev/null
echo "jq:        $(grep -c "^jq$" "$COUNTERS" 2>/dev/null || echo 0)"
echo "systemctl: $(grep -c "^systemctl$" "$COUNTERS" 2>/dev/null || echo 0)"
echo "sing-box:  $(grep -c "^sing-box$" "$COUNTERS" 2>/dev/null || echo 0)"
echo "openssl:   $(grep -c "^openssl$" "$COUNTERS" 2>/dev/null || echo 0)"
echo "curl:      $(grep -c "^curl$" "$COUNTERS" 2>/dev/null || echo 0)"

# ---- Phase 2: second call — cache should hit, no extra sing-box ----
echo ""
echo "--- node_summary (2nd call, cache warm) ---"
> "$COUNTERS"
node_summary > /dev/null
echo "jq:        $(grep -c "^jq$" "$COUNTERS" 2>/dev/null || echo 0)"
echo "systemctl: $(grep -c "^systemctl$" "$COUNTERS" 2>/dev/null || echo 0)"
echo "sing-box:  $(grep -c "^sing-box$" "$COUNTERS" 2>/dev/null || echo 0)"

# ---- Phase 3: list_inbounds ----
echo ""
echo "--- list_inbounds ---"
> "$COUNTERS"
list_inbounds > /dev/null
echo "jq:        $(grep -c "^jq$" "$COUNTERS" 2>/dev/null || echo 0)"

# ---- Phase 4: sing_box_version (cached) ----
echo ""
echo "--- sing_box_version (3 calls) ---"
> "$COUNTERS"
sing_box_version > /dev/null
sing_box_version > /dev/null
sing_box_version > /dev/null
echo "sing-box:  $(grep -c "^sing-box$" "$COUNTERS" 2>/dev/null || echo 0)  (expected: 1 — cached after first)"

# ---- Phase 5: service_state_summary + startup_state_summary ----
echo ""
echo "--- service_state_summary + startup_state_summary ---"
> "$COUNTERS"
service_state_summary > /dev/null
startup_state_summary > /dev/null
echo "systemctl: $(grep -c "^systemctl$" "$COUNTERS" 2>/dev/null || echo 0)"

# ---- Phase 6: init_system (cached after module load) ----
echo ""
echo "--- init_system (3 calls, already cached from module load) ---"
> "$COUNTERS"
init_system > /dev/null
init_system > /dev/null
init_system > /dev/null
echo "sing-box:  $(grep -c "^sing-box$" "$COUNTERS" 2>/dev/null || echo 0)"

echo ""
echo "=== Counts collected ==="
' 2>&1

# ---- Assertions ----
echo ""
echo "--- Assertions ---"

# Count jq calls from Phase 3 (list_inbounds)
> "$COUNTERS"
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
> "$COUNTERS"
list_inbounds > /dev/null
jq_count=$(grep -c "^jq$" "$COUNTERS" 2>/dev/null || echo 0)
printf "%s\n" "$jq_count"
' > "$TMP/list_jq_count" 2>/dev/null
list_jq=$(cat "$TMP/list_jq_count" 2>/dev/null || echo 0)
assert_le "list_inbounds jq calls" "${list_jq:-0}" 2

# node_summary: max assertions
> "$COUNTERS"
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
> "$COUNTERS"
node_summary > /dev/null
sc=$(grep -c "^systemctl$" "$COUNTERS" 2>/dev/null || echo 0)
sb=$(grep -c "^sing-box$" "$COUNTERS" 2>/dev/null || echo 0)
curl_c=$(grep -c "^curl$" "$COUNTERS" 2>/dev/null || echo 0)
printf "%s %s %s\n" "$sc" "$sb" "$curl_c"
' > "$TMP/node_counts" 2>/dev/null
read -r node_sc node_sb node_curl < "$TMP/node_counts" 2>/dev/null || true
assert_le "node_summary systemctl calls" "${node_sc:-0}" 1
assert_le "node_summary sing-box calls"   "${node_sb:-0}" 1
assert_le "node_summary curl calls"       "${node_curl:-0}" 0

# sing_box_version cache: single execution
> "$COUNTERS"
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
> "$COUNTERS"
sing_box_version > /dev/null
sing_box_version > /dev/null
sing_box_version > /dev/null
grep -c "^sing-box$" "$COUNTERS" 2>/dev/null || echo 0
' > "$TMP/ver_count" 2>/dev/null
ver_calls=$(cat "$TMP/ver_count" 2>/dev/null || echo 0)
assert_le "sing_box_version (3 calls) sing-box exec" "${ver_calls:-0}" 1

# ---- structure assertions ----
echo ""
echo "--- Structure ---"
if grep -rn 'declare -f' lib/ sbctl.sh 2>/dev/null; then
  echo '  FAIL: declare -f override found'
  ((failures+=1))
else
  echo '  ok   zero declare -f overrides'
fi

# ---- module list sync check ----
echo ""
echo "--- MODULES sync ---"
sbctl_modules=$(grep '^for _module in ' sbctl.sh | sed 's/.*for _module in //' | sed 's/; do//' | tr ' ' '\n' | sort)
install_modules=$(grep '^readonly MODULES=' install.sh | sed 's/readonly MODULES="//;s/"//' | tr ' ' '\n' | sort)
alpine_modules=$(grep '^MODULES=' alpine/install.sh | sed 's/MODULES="//;s/"//' | tr ' ' '\n' | sort)

if [[ "$sbctl_modules" == "$install_modules" ]]; then
  echo '  ok   sbctl.sh == install.sh MODULES'
else
  echo '  FAIL sbctl.sh != install.sh MODULES' >&2
  diff <(echo "$sbctl_modules") <(echo "$install_modules") >&2 || true
  ((failures+=1))
fi

if [[ "$sbctl_modules" == "$alpine_modules" ]]; then
  echo '  ok   sbctl.sh == alpine/install.sh MODULES'
else
  echo '  FAIL sbctl.sh != alpine/install.sh MODULES' >&2
  diff <(echo "$sbctl_modules") <(echo "$alpine_modules") >&2 || true
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
