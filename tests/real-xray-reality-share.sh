#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REAL_BIN=${SBCTL_REAL_SING_BOX_BIN:-sing-box}
XRAY_BIN=${SBCTL_REAL_XRAY_BIN:-xray}
if ! command -v "$REAL_BIN" >/dev/null || ! command -v "$XRAY_BIN" >/dev/null; then
  echo 'set SBCTL_REAL_SING_BOX_BIN and SBCTL_REAL_XRAY_BIN' >&2; exit 1
fi
T=$(mktemp -d)
trap 'kill ${http_pid:-} ${server_pid:-} ${client_pid:-} ${tls_pid:-} 2>/dev/null || true; rm -rf "$T"' EXIT
export SBCTL_TESTING=1 SBCTL_CONFIG_DIR="$T/config" SBCTL_CONFIG_FILE="$T/config/config.json" SBCTL_META_FILE="$T/meta.json" SBCTL_CERT_DIR="$T/config/certs" SBCTL_LOCK_FILE="$T/lock"
# shellcheck source=/dev/null
source ./sbctl.sh
mkdir -p "$CONFIG_DIR"
IFS=' ' read -r server_port client_port http_port tls_port < <(python3 -c 'import socket; s=[socket.socket() for _ in range(4)]; [x.bind(("127.0.0.1",0)) for x in s]; print(*(x.getsockname()[1] for x in s))')
keys=$("$REAL_BIN" generate reality-keypair)
private=$(awk '/PrivateKey/ {print $NF}' <<<"$keys")
public=$(awk '/PublicKey/ {print $NF}' <<<"$keys")
sha=$(printf '%s' "$private" | openssl dgst -sha256 -r | awk '{print $1}')
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/key.pem" -out "$T/cert.pem" -days 1 -subj '/CN=example.test' >/dev/null 2>&1
openssl s_server -quiet -accept "127.0.0.1:$tls_port" -cert "$T/cert.pem" -key "$T/key.pem" >"$T/tls.log" 2>&1 & tls_pid=$!
jq -n --argjson port "$server_port" --argjson target "$tls_port" --arg private "$private" '{inbounds:[{type:"vless",tag:"test",listen:"127.0.0.1",listen_port:$port,users:[{name:"user",uuid:"5ec08bdf-bfce-4931-8806-21759feb0f10",flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:"example.test",reality:{enabled:true,handshake:{server:"127.0.0.1",server_port:$target},private_key:$private,short_id:["01234567"]}}}],outbounds:[{type:"direct",tag:"direct"}],route:{final:"direct"}}' >"$CONFIG_FILE"
jq -n --arg public "$public" --arg sha "$sha" '{inbounds:{test:{host:"127.0.0.1",realityPublicKey:$public,realityPrivateSHA256:$sha}}}' >"$META_FILE"
link=$(print_share test | sed -n 's/^链接: //p')
python3 - "$link" "$client_port" "$T/client.json" <<'PY'
import json,sys
from urllib.parse import urlsplit,parse_qs,unquote
u=urlsplit(sys.argv[1]); q=parse_qs(u.query)
assert u.scheme=='vless' and q['security']==['reality'] and q['flow']==['xtls-rprx-vision']
config={'inbounds':[{'protocol':'socks','listen':'127.0.0.1','port':int(sys.argv[2])}],'outbounds':[{'protocol':'vless','settings':{'vnext':[{'address':u.hostname,'port':u.port,'users':[{'id':unquote(u.username),'encryption':'none','flow':q['flow'][0]}]}]},'streamSettings':{'network':'tcp','security':'reality','realitySettings':{'serverName':q['sni'][0],'fingerprint':q['fp'][0],'password':q['pbk'][0],'shortId':q['sid'][0],'spiderX':'/'}}}]}
with open(sys.argv[3],'w') as f: json.dump(config,f)
PY
printf 'reality-ok\n' >"$T/index.html"
python3 -m http.server "$http_port" --bind 127.0.0.1 --directory "$T" >"$T/http.log" 2>&1 & http_pid=$!
"$REAL_BIN" run -c "$CONFIG_FILE" >"$T/server.log" 2>&1 & server_pid=$!
"$XRAY_BIN" run -c "$T/client.json" >"$T/client.log" 2>&1 & client_pid=$!
for _ in {1..40}; do
  if output=$(curl -fsS --max-time 2 --noproxy '' --proxy "socks5h://127.0.0.1:$client_port" "http://127.0.0.1:$http_port/" 2>/dev/null); then
    [[ $output == reality-ok ]]; echo 'real Xray to sing-box VLESS REALITY share fields passed.'; exit 0
  fi
  sleep 0.1
done
cat "$T/server.log" "$T/client.log" "$T/tls.log" >&2
exit 1
