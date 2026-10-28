#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REAL_BIN=${SBCTL_REAL_SING_BOX_BIN:-sing-box}
command -v "$REAL_BIN" >/dev/null || { printf 'set SBCTL_REAL_SING_BOX_BIN to a sing-box executable\n' >&2; exit 1; }
T=$(mktemp -d)
trap 'kill ${http_pid:-} ${server_pid:-} ${client_pid:-} 2>/dev/null || true; rm -rf "$T"' EXIT
export SBCTL_TESTING=1 SBCTL_CONFIG_DIR="$T/config" SBCTL_CONFIG_FILE="$T/config/config.json" SBCTL_META_FILE="$T/meta.json" SBCTL_CERT_DIR="$T/config/certs" SBCTL_LOCK_FILE="$T/lock"
source ./sbctl.sh
mkdir -p "$CONFIG_DIR"
IFS=" " read -r server_port client_port http_port < <(python3 -c 'import socket; s=[socket.socket() for _ in range(3)]; [x.bind(("127.0.0.1",0)) for x in s]; print(*(x.getsockname()[1] for x in s))')
jq -n --argjson port "$server_port" '{inbounds:[{type:"vless",tag:"test",listen:"127.0.0.1",listen_port:$port,users:[{name:"user",uuid:"5ec08bdf-bfce-4931-8806-21759feb0f10"}],transport:{type:"ws",path:"/test-path",headers:{Host:"example.test"}}}],outbounds:[{type:"direct",tag:"direct"}],route:{final:"direct"}}' >"$CONFIG_FILE"
printf '%s\n' '{"inbounds":{"test":{"host":"127.0.0.1"}}}' >"$META_FILE"
link=$(print_share test | sed -n 's/^链接: //p')
python3 - "$link" "$client_port" "$T/client.json" <<'PY'
import json, sys
from urllib.parse import urlsplit, parse_qs, unquote
uri = urlsplit(sys.argv[1]); query = parse_qs(uri.query)
assert uri.scheme == 'vless' and query['type'] == ['ws'] and query.get('security', ['none']) == ['none']
config = {'inbounds': [{'type': 'socks', 'listen': '127.0.0.1', 'listen_port': int(sys.argv[2])}],
          'outbounds': [{'type': 'vless', 'tag': 'proxy', 'server': uri.hostname, 'server_port': uri.port,
                         'uuid': unquote(uri.username), 'transport': {'type': 'ws', 'path': query['path'][0],
                         'headers': {'Host': query['host'][0]}}}], 'route': {'final': 'proxy'}}
with open(sys.argv[3], 'w') as output: json.dump(config, output)
PY
printf 'sbctl-real-vless-ws\n' >"$T/index.html"
python3 -m http.server "$http_port" --bind 127.0.0.1 --directory "$T" >"$T/http.log" 2>&1 & http_pid=$!
"$REAL_BIN" run -c "$CONFIG_FILE" >"$T/server.log" 2>&1 & server_pid=$!
"$REAL_BIN" run -c "$T/client.json" >"$T/client.log" 2>&1 & client_pid=$!
for attempt in {1..30}; do
  if output=$(curl --silent --show-error --fail --max-time 2 --noproxy '' --proxy "socks5h://127.0.0.1:$client_port" "http://127.0.0.1:$http_port/" 2>/dev/null); then
    [[ $output == sbctl-real-vless-ws ]]
    printf 'real sing-box VLESS WebSocket share fields passed.\n'
    exit 0
  fi
  sleep 0.1
done
cat "$T/server.log" "$T/client.log" "$T/http.log" >&2
exit 1
