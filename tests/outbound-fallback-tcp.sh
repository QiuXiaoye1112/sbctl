#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

[[ $(uname -s) == Linux ]] || { printf 'real fallback TCP test requires Linux\n' >&2; exit 1; }
((EUID == 0)) || { printf 'real fallback TCP test requires root for a network namespace\n' >&2; exit 1; }
command -v ip >/dev/null || { printf 'real fallback TCP test requires iproute2\n' >&2; exit 1; }
command -v python3 >/dev/null || { printf 'real fallback TCP test requires python3\n' >&2; exit 1; }

REAL_BIN=${SBCTL_REAL_SING_BOX_BIN:-$(command -v sing-box 2>/dev/null || true)}
[[ -x $REAL_BIN ]] || { printf 'set SBCTL_REAL_SING_BOX_BIN to a real sing-box binary\n' >&2; exit 1; }
REAL_BIN=$(readlink -f "$REAL_BIN")
EXPECTED_SERIES=${SBCTL_EXPECT_SING_BOX_SERIES:-1.13}
REAL_VERSION=$("$REAL_BIN" version | sed -nE '1s/^sing-box version ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')
[[ $REAL_VERSION == "$EXPECTED_SERIES".* ]] || {
  printf 'expected sing-box %s.x, got %s\n' "$EXPECTED_SERIES" "${REAL_VERSION:-unknown}" >&2
  exit 1
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/sbctl-fallback-real.XXXXXX")
NS="sbctl-fb-$RANDOM-$$"
HARNESS_PID=''
SING_BOX_PID=''
cleanup() {
  set +e
  [[ -z $SING_BOX_PID ]] || kill "$SING_BOX_PID" 2>/dev/null
  [[ -z $HARNESS_PID ]] || kill "$HARNESS_PID" 2>/dev/null
  [[ -z $SING_BOX_PID ]] || wait "$SING_BOX_PID" 2>/dev/null
  [[ -z $HARNESS_PID ]] || wait "$HARNESS_PID" 2>/dev/null
  ip netns del "$NS" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

IPV4_SOURCE=192.0.2.2
IPV6_SOURCE=fd42:7362:6374::2
IPV6_BLACKHOLE=fd42:7362:6374::99
DNS_PORT=15353
TCP_PORT=18080
SOCKS_PORT=1080
EVENTS="$TMP/events.jsonl"
READY="$TMP/ready"
CONFIG="$TMP/config.json"

ip netns add "$NS"
ip -n "$NS" link set lo up
ip -n "$NS" link add sbctl0 type veth peer name sink0
ip -n "$NS" address add "$IPV4_SOURCE/24" dev sbctl0
ip -n "$NS" -6 address add "$IPV6_SOURCE/64" dev sbctl0 nodad
ip -n "$NS" link set sbctl0 up
ip -n "$NS" link set sink0 up

cat >"$CONFIG" <<JSON
{
  "log": {"level": "warn", "timestamp": true},
  "dns": {
    "servers": [
      {"type": "udp", "tag": "sbctl-local-dns", "server": "127.0.0.1", "server_port": $DNS_PORT}
    ]
  },
  "inbounds": [
    {"type": "socks", "tag": "socks-in", "listen": "127.0.0.1", "listen_port": $SOCKS_PORT}
  ],
  "outbounds": [
    {"type": "direct", "tag": "dns-direct"},
    {
      "type": "direct",
      "tag": "fallback",
      "inet6_bind_address": "$IPV6_SOURCE",
      "inet4_bind_address": "$IPV4_SOURCE",
      "domain_resolver": {"server": "sbctl-local-dns", "strategy": "prefer_ipv6"},
      "fallback_delay": "300ms"
    }
  ],
  "route": {
    "auto_detect_interface": false,
    "rules": [
      {"ip_cidr": ["127.0.0.0/8"], "action": "route", "outbound": "dns-direct"}
    ],
    "final": "fallback"
  }
}
JSON

ip netns exec "$NS" "$REAL_BIN" check -c "$CONFIG"

ip netns exec "$NS" python3 tests/helpers/fallback_lab.py serve \
  --events "$EVENTS" --ready "$READY" --ipv4 "$IPV4_SOURCE" --ipv6 "$IPV6_BLACKHOLE" \
  --dns-port "$DNS_PORT" --tcp-port "$TCP_PORT" &
HARNESS_PID=$!
for _ in {1..100}; do
  [[ -f $READY ]] && break
  kill -0 "$HARNESS_PID" 2>/dev/null || { printf 'fallback lab exited before readiness\n' >&2; exit 1; }
  sleep 0.05
done
[[ -f $READY ]] || { printf 'fallback lab readiness timed out\n' >&2; exit 1; }

ip netns exec "$NS" "$REAL_BIN" run -c "$CONFIG" >"$TMP/sing-box.log" 2>&1 &
SING_BOX_PID=$!
if ! ip netns exec "$NS" python3 tests/helpers/fallback_lab.py connect \
  --events "$EVENTS" --socks-port "$SOCKS_PORT" --tcp-port "$TCP_PORT" >"$TMP/client.out"; then
  cat "$TMP/sing-box.log" >&2
  exit 1
fi
grep -Fxq fallback-ok "$TMP/client.out"
ip -n "$NS" -6 neighbour show to "$IPV6_BLACKHOLE" | grep -Fq "$IPV6_BLACKHOLE"
python3 tests/helpers/fallback_lab.py assert --events "$EVENTS"
printf 'real sing-box %s TCP fallback test passed.\n' "$REAL_VERSION"
