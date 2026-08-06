#!/usr/bin/env bash
# Performance baseline measurement for sbctl optimization.
# Counts external process invocations during key operations.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Create mock environment
MOCK_DIR=$(mktemp -d /tmp/sbctl-perf-XXXXXX)
trap 'rm -rf "$MOCK_DIR"' EXIT

mkdir -p "$MOCK_DIR/etc/sing-box/certs"
mkdir -p "$MOCK_DIR/var/lib/sbctl"
mkdir -p "$MOCK_DIR/usr/local/bin"
mkdir -p "$MOCK_DIR/usr/local/sbin"
mkdir -p "$MOCK_DIR/usr/local/lib/sbctl"

# Create a mock config
cat > "$MOCK_DIR/etc/sing-box/config.json" << 'JSON'
{
  "log": {"level": "warn", "timestamp": true},
  "inbounds": [
    {
      "type": "vless", "tag": "test-vless",
      "listen": "0.0.0.0", "listen_port": 443,
      "users": [{"name": "user1", "uuid": "00000000-0000-0000-0000-000000000001", "flow": "xtls-rprx-vision"}],
      "tls": {"enabled": true, "server_name": "example.com",
        "reality": {"enabled": true, "handshake": {"server": "www.microsoft.com", "server_port": 443},
        "private_key": "test-key", "short_id": ["abcd"]},
        "certificate_path": "/etc/sing-box/certs/test.crt",
        "key_path": "/etc/sing-box/certs/test.key"}
    },
    {
      "type": "trojan", "tag": "test-trojan",
      "listen": "0.0.0.0", "listen_port": 8443,
      "users": [{"name": "trojan1", "password": "test-pass"}],
      "tls": {"enabled": true, "server_name": "trojan.example.com",
        "certificate_path": "/etc/sing-box/certs/trojan.crt",
        "key_path": "/etc/sing-box/certs/trojan.key"}
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "route": {"final": "direct"}
}
JSON

cat > "$MOCK_DIR/var/lib/sbctl/meta.json" << 'JSON'
{"schema":2,"inbounds":{"test-vless":{"host":"1.2.3.4","updatedAt":"2024-01-01T00:00:00Z","realityPublicKey":"test-pub","realityPrivateSHA256":"test-sha"},"test-trojan":{"host":"trojan.example.com","updatedAt":"2024-01-01T00:00:00Z"}},"certificates":{},"managedResources":{},"migrations":{"legacyCertScanV1":true}}
JSON

# Create mock binaries that count invocations
for cmd in jq systemctl sing-box openssl sed curl; do
  cat > "$MOCK_DIR/usr/local/bin/$cmd" << 'SCRIPT'
#!/usr/bin/env bash
echo "${0##*/}" >> /tmp/sbctl-perf-counts.log
case "${0##*/}" in
  jq)
    # Pass through to real jq for functionality
    exec /usr/bin/jq "$@"
    ;;
  systemctl)
    if [[ "$*" == *"is-active"* ]]; then echo inactive; exit 0
    elif [[ "$*" == *"is-enabled"* ]]; then echo disabled; exit 0
    elif [[ "$*" == *"list-unit-files"* ]]; then exit 0
    elif [[ "$*" == *"show"* ]]; then echo "LoadState=loaded"; echo "ActiveState=inactive"; echo "UnitFileState=disabled"; exit 0
    else exit 0; fi
    ;;
  sing-box)
    if [[ "$*" == *"version"* ]]; then echo "sing-box version 1.14.0"; exit 0
    elif [[ "$*" == *"check"* ]]; then exit 0
    elif [[ "$*" == *"generate"* ]]; then echo "PrivateKey: test-key"; echo "PublicKey: test-pub"; exit 0
    else exit 0; fi
    ;;
  openssl) exec /usr/bin/openssl "$@" ;;
  sed) exec /usr/bin/sed "$@" ;;
  curl) exit 0 ;;
esac
SCRIPT
  chmod +x "$MOCK_DIR/usr/local/bin/$cmd"
done

# Also add real binaries needed
for cmd in date tr head tail awk grep cat cp mv rm mkdir chmod readlink dirname basename install; do
  ln -sf "$(command -v "$cmd")" "$MOCK_DIR/usr/local/bin/$cmd" 2>/dev/null || true
done

# Count function overrides
echo "=== STRUCTURE BASELINE ==="
echo "declare -f occurrences:"
grep -rn 'declare -f' "$PROJECT_DIR/lib/" | wc -l

echo ""
echo "Duplicate function definitions (≥2 files):"
grep -rn '^[a-z_]*()' "$PROJECT_DIR/lib/"*.sh | awk -F: '{print $3}' | sed 's/()//' | sort | uniq -c | sort -rn | awk '$1>=2' | wc -l
echo "functions defined in ≥2 files"

echo ""
echo "Total lines of code:"
wc -l "$PROJECT_DIR"/sbctl.sh "$PROJECT_DIR"/lib/*.sh | tail -1

echo ""
echo "Module count:"
ls "$PROJECT_DIR"/lib/*.sh | wc -l

echo ""
echo "=== FUNCTION OVERRIDE CHAIN ==="
grep -rn 'declare -f' "$PROJECT_DIR/lib/" || echo "(none found)"

echo ""
echo "=== DUPLICATE FUNCTION DEFINITIONS ==="
grep -rn '^[a-z_]*()' "$PROJECT_DIR/lib/"*.sh | awk -F: '{print $3}' | sed 's/()//' | sort | uniq -c | sort -rn | awk '$1>=2{print}'

echo ""
echo "=== PERF COUNTER SIMULATION ==="
# Simulate the key operations and count jq/systemctl calls
rm -f /tmp/sbctl-perf-counts.log

# Simulate node_summary (what main menu calls)
echo "--- main menu (node_summary + list_inbounds) ---"
export PATH="$MOCK_DIR/usr/local/bin:$PATH"
export SBCTL_TESTING=1
export SBCTL_CONFIG_DIR="$MOCK_DIR/etc/sing-box"
export SBCTL_META_FILE="$MOCK_DIR/var/lib/sbctl/meta.json"
export SBCTL_SING_BOX_BIN="$MOCK_DIR/usr/local/bin/sing-box"
export SBCTL_LIB_DIR="$PROJECT_DIR/lib"

# Count what a typical main_menu render does
rm -f /tmp/sbctl-perf-counts.log
bash -c "
export PATH=\"$MOCK_DIR/usr/local/bin:\$PATH\"
export SBCTL_TESTING=1
export SBCTL_CONFIG_DIR=\"$MOCK_DIR/etc/sing-box\"
export SBCTL_META_FILE=\"$MOCK_DIR/var/lib/sbctl/meta.json\"
export SBCTL_SING_BOX_BIN=\"$MOCK_DIR/usr/local/bin/sing-box\"

# Simulate node_summary calls
# refresh_binary_path
\"$MOCK_DIR/usr/local/bin/sing-box\" version >/dev/null 2>&1 || true
# service_exists -> init_system + systemctl
\"$MOCK_DIR/usr/local/bin/systemctl\" list-unit-files sing-box.service --no-legend >/dev/null 2>&1 || true
# service_is_active -> init_system + systemctl
\"$MOCK_DIR/usr/local/bin/systemctl\" is-active --quiet sing-box >/dev/null 2>&1 || true
# jq for inbounds count
\"$MOCK_DIR/usr/local/bin/jq\" '.inbounds|length' \"$MOCK_DIR/etc/sing-box/config.json\"

# Simulate list_inbounds
\"$MOCK_DIR/usr/local/bin/jq\" '.inbounds|length' \"$MOCK_DIR/etc/sing-box/config.json\"
\"$MOCK_DIR/usr/local/bin/jq\" -r '.inbounds[] | [.tag,.type,(.listen_port|tostring),(if .tls.reality.enabled==true then \"reality\" elif .tls.enabled==true then \"tls\" else \"none\" end),((.users//[])|length|tostring)] | @tsv' \"$MOCK_DIR/etc/sing-box/config.json\"
" 2>/dev/null || true

echo "jq calls: $(grep -c '^jq$' /tmp/sbctl-perf-counts.log 2>/dev/null || echo 0)"
echo "systemctl calls: $(grep -c '^systemctl$' /tmp/sbctl-perf-counts.log 2>/dev/null || echo 0)"
echo "sing-box calls: $(grep -c '^sing-box$' /tmp/sbctl-perf-counts.log 2>/dev/null || echo 0)"

echo ""
echo "=== COMPLETE ==="
