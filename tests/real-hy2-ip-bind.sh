#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REAL_BIN=${SBCTL_REAL_SING_BOX_BIN:-sing-box}
backend=${SBCTL_TEST_BACKEND:-nft}
command -v "$REAL_BIN" >/dev/null || { echo 'set SBCTL_REAL_SING_BOX_BIN' >&2; exit 1; }
if [[ ${1-} != --worker ]]; then
  exec unshare --net --mount bash "$0" --worker
fi
[[ $(readlink /proc/self/ns/net) != "$(readlink /proc/1/ns/net)" ]] || exit 1
T=$(mktemp -d)
NS="sbctl-hy2-ip-$$"
cleanup() {
  local pid
  for pid in "${http_pid:-}" "${server_pid:-}" "${client_pid:-}"; do
    [[ -z $pid ]] || kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  ip netns del "$NS" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT

# The temporary network namespace registry belongs to the private mount namespace.
mount -t tmpfs tmpfs /run
mkdir -p /run/netns
mount --bind /run/netns /run/netns
mount --make-rshared /run/netns
ip netns add "$NS"
ip link add sbctl-server type veth peer name sbctl-client
ip link set sbctl-client netns "$NS"
ip link set lo up
ip link set sbctl-server up
ip addr add 192.0.2.10/24 dev sbctl-server
ip -6 addr add 2001:db8::10/64 dev sbctl-server nodad
ip netns exec "$NS" ip link set lo up
ip netns exec "$NS" ip link set sbctl-client up
ip netns exec "$NS" ip addr add 192.0.2.20/24 dev sbctl-client
ip netns exec "$NS" ip -6 addr add 2001:db8::20/64 dev sbctl-client nodad

export SBCTL_TESTING=1 SBCTL_CONFIG_DIR="$T/config" SBCTL_CONFIG_FILE="$T/config/config.json"
export SBCTL_META_FILE="$T/meta.json" SBCTL_CERT_DIR="$T/config/certs" SBCTL_LOCK_FILE="$T/lock"
export SBCTL_TRAFFIC_FILE="$T/traffic.json" SBCTL_TRAFFIC_BACKEND="$backend"
export SBCTL_SING_BOX_BIN="$REAL_BIN" SBCTL_TRAFFIC_NOW='2026-11-25 12:00:00'
# shellcheck source=/dev/null
source ./sbctl.sh
if [[ $backend == iptables ]]; then
  command_exists() { [[ $1 != nft ]] && command -v "$1" >/dev/null 2>&1; }
fi
write_default_config
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/key.pem" -out "$T/cert.pem" \
  -days 1 -subj '/CN=fixture.example' -addext 'subjectAltName=DNS:fixture.example' >/dev/null 2>&1
tls=$(jq -nc --arg cert "$T/cert.pem" --arg key "$T/key.pem" \
  '{enabled:true,server_name:"fixture.example",certificate_path:$cert,key_path:$key}')
hy2_build inbound_v4 hy2-v4 192.0.2.10 443 test password-v4 '' '' '' "$tls"
hy2_build inbound_v6 hy2-v6 2001:db8::10 443 test password-v6 '' '' '' "$tls"
jq -n --argjson v4 "$inbound_v4" --argjson v6 "$inbound_v6" \
  '{inbounds:[$v4,$v6],outbounds:[{type:"direct",tag:"direct"}],route:{final:"direct"}}' >"$CONFIG_FILE"
printf '%s\n' '{"inbounds":{
  "hy2-v4":{"host":"192.0.2.10","hysteria2PortHopping":{"enabled":true,"range":"30000-30009"}},
  "hy2-v6":{"host":"2001:db8::10","hysteria2PortHopping":{"enabled":true,"range":"30000-30009"}}
}}' >"$META_FILE"
hy2_hop_check_conflicts 30000-30009 hy2-v6 2001:db8::10
if hy2_hop_check_conflicts 30000-30009 hy2-v6 192.0.2.10; then exit 1; fi
{ print_share hy2-v4; print_share hy2-v6; } >"$T/links"
python3 - "$T/cert.pem" "$T/client.json" "$T/links" <<'PY'
import json
import sys
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

config = {"inbounds": [], "outbounds": [], "route": {"rules": []}}
links = [line.removeprefix("链接: ") for line in Path(sys.argv[3]).read_text().splitlines()
         if line.startswith("链接: hysteria2://")]
assert len(links) == 2
for link, address, socks_port in zip(links, ("192.0.2.10", "2001:db8::10"), (24004, 24006)):
    uri = urlsplit(link)
    port_range = uri.netloc.rsplit(":", 1)[-1]
    assert uri.hostname == address and port_range == "30000-30009"
    query = parse_qs(uri.query)
    tag = str(socks_port)
    config["inbounds"].append({"type": "socks", "tag": tag, "listen": "127.0.0.1", "listen_port": socks_port})
    config["outbounds"].append({
        "type": "hysteria2", "tag": tag + "-out", "server": address,
        "server_ports": [port_range.replace("-", ":")], "hop_interval": "1s",
        "password": unquote(uri.username),
        "tls": {"enabled": True, "server_name": query["sni"][0], "certificate_path": sys.argv[1]},
    })
    config["route"]["rules"].append({"inbound": [tag], "action": "route", "outbound": tag + "-out"})
Path(sys.argv[2]).write_text(json.dumps(config))
PY

"$REAL_BIN" check -c "$CONFIG_FILE"
"$REAL_BIN" check -c "$T/client.json"
hy2_hop_restore_all
traffic_init_file
traffic_set_backend "$backend"
traffic_rules_restore
printf '%s\n' 'hop-ok' >"$T/index.html"
python3 -m http.server 24000 --bind 192.0.2.10 --directory "$T" >"$T/http.log" 2>&1 & http_pid=$!
"$REAL_BIN" run -c "$CONFIG_FILE" >"$T/server.log" 2>&1 & server_pid=$!
ip netns exec "$NS" "$REAL_BIN" run -c "$T/client.json" >"$T/client.log" 2>&1 & client_pid=$!

fetch() {
  ip netns exec "$NS" curl -fsS --max-time 4 --noproxy '' \
    --proxy "socks5h://127.0.0.1:$1" http://192.0.2.10:24000/
}
for _ in {1..30}; do
  if output=$(fetch 24004 2>/dev/null) && [[ $output == hop-ok ]]; then break; fi
  kill -0 "$server_pid" "$client_pid" || { cat "$T/server.log" "$T/client.log" >&2; exit 1; }
  sleep .1
done
[[ ${output:-} == hop-ok ]] || { cat "$T/server.log" "$T/client.log" >&2; exit 1; }
traffic_read_counters | traffic_samples_json | jq -e '.["hy2-v4"] > 0 and .["hy2-v6"] == 0' >/dev/null
[[ $(fetch 24006) == hop-ok ]]
sleep 2
[[ $(fetch 24004) == hop-ok && $(fetch 24006) == hop-ok ]]
traffic_read_counters | traffic_samples_json | jq -e '.["hy2-v4"] > 0 and .["hy2-v6"] > 0' >/dev/null

# The input hook sees the translated port.
jq '.enabled=true | .limitsEnabled=true | .inbounds["hy2-v4"].limit={enabled:true,quotaBytes:1,usedBytes:1,
  anchorDay:1,anchorTime:"00:00",cycleStart:"2026-11-01 00:00:00",cycleEnd:"2026-12-01 00:00:00"}' \
  "$TRAFFIC_FILE" >"$T/limits.json"
mv "$T/limits.json" "$TRAFFIC_FILE"
traffic_rules_restore
if fetch 24004 >/dev/null 2>&1; then echo 'IPv4 quota did not block the hopped connection' >&2; exit 1; fi
[[ $(fetch 24006) == hop-ok ]]
traffic_read_counters | traffic_samples_json | jq -e '.["hy2-v4"] == 0 and .["hy2-v6"] > 0' >/dev/null

# Use the real listener edit transaction with a process local to this lab.
hy2_hop_boot_service_ensure() { :; }
service_is_active() { kill -0 "$server_pid" 2>/dev/null; }
restart_service_checked() {
  kill "$server_pid" || return 1
  wait "$server_pid" || true
  "$REAL_BIN" run -c "$CONFIG_FILE" >"$T/server.log" 2>&1 & server_pid=$!
}
old_link=$(print_share hy2-v6 | sed -n 's/^链接: //p')
modify_inbound_basic hy2-v6 port <<<'8443'
jq -e '.inbounds["hy2-v4"].port==443 and .inbounds["hy2-v4"].limit.usedBytes==1 and
  .inbounds["hy2-v6"].port==8443 and .inbounds["hy2-v6"].cycles["2026-11-01 00:00:00"]>0' "$TRAFFIC_FILE" >/dev/null
[[ $(print_share hy2-v6 | sed -n 's/^链接: //p') == "$old_link" ]]
kill "$client_pid"
wait "$client_pid" || true
ip netns exec "$NS" "$REAL_BIN" run -c "$T/client.json" >"$T/client.log" 2>&1 & client_pid=$!
for _ in {1..10}; do
  if output=$(fetch 24006 2>/dev/null) && [[ $output == hop-ok ]]; then break; fi
  sleep .1
done
[[ ${output:-} == hop-ok ]] || { cat "$T/server.log" "$T/client.log" >&2; exit 1; }
if fetch 24004 >/dev/null 2>&1; then echo 'IPv4 quota was lost after listener edit' >&2; exit 1; fi
printf 'real Hysteria2 %s: shared UDP 443 and hop range, separate counters and quota block passed.\n' "$backend"
