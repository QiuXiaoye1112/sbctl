#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REAL_BIN=${SBCTL_REAL_SING_BOX_BIN:-sing-box}
command -v "$REAL_BIN" >/dev/null || { echo 'set SBCTL_REAL_SING_BOX_BIN' >&2; exit 1; }
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
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/key.pem" -out "$T/cert.pem" -days 1 -subj '/CN=example.test' -addext 'subjectAltName=DNS:example.test' >/dev/null 2>&1
openssl s_server -quiet -accept "127.0.0.1:$tls_port" -cert "$T/cert.pem" -key "$T/key.pem" >"$T/tls.log" 2>&1 & tls_pid=$!
printf 'extra-ok\n' >"$T/index.html"
python3 -m http.server "$http_port" --bind 127.0.0.1 --directory "$T" >"$T/http.log" 2>&1 & http_pid=$!
for mode in trojan-reality anytls-reality trojan-ws; do
  protocol=${mode%-*}
  jq -n --arg type "$protocol" --argjson port "$server_port" --arg cert "$T/cert.pem" --arg key "$T/key.pem" '{inbounds:[{type:$type,tag:"test",listen:"127.0.0.1",listen_port:$port,users:[{name:"user",password:"test-password"}],tls:{enabled:true,server_name:"example.test",certificate_path:$cert,key_path:$key}}],outbounds:[{type:"direct",tag:"direct"}],route:{final:"direct"}}' >"$CONFIG_FILE"
  if [[ $mode == *-reality ]]; then
    jq --arg private "$private" --argjson target "$tls_port" '.inbounds[0].tls |= (del(.certificate_path,.key_path) + {reality:{enabled:true,handshake:{server:"127.0.0.1",server_port:$target},private_key:$private,short_id:["01234567"]}})' "$CONFIG_FILE" >"$T/tmp"; mv "$T/tmp" "$CONFIG_FILE"
  else
    jq '.inbounds[0].transport={type:"ws",path:"/test",headers:{Host:"example.test"}}' "$CONFIG_FILE" >"$T/tmp"; mv "$T/tmp" "$CONFIG_FILE"
  fi
  jq -n --arg public "$public" --arg sha "$sha" '{inbounds:{test:{host:"127.0.0.1",realityPublicKey:$public,realityPrivateSHA256:$sha}}}' >"$META_FILE"
  if [[ $mode == anytls-reality ]]; then
    print_share test | sed -n '/^客户端 outbound JSON: /,$p' | sed '1s/^客户端 outbound JSON: //' | sed '/^------------------------------------------------------------------------/,$d' >"$T/outbound.json"
  else
    link=$(print_share test | sed -n 's/^链接: //p')
    python3 - "$link" "$mode" "$T/cert.pem" "$T/outbound.json" <<'PY'
import json,sys
from urllib.parse import urlsplit,parse_qs,unquote
u=urlsplit(sys.argv[1]); q=parse_qs(u.query); mode=sys.argv[2]
assert u.scheme=='trojan'
out={'type':'trojan','tag':'proxy','server':u.hostname,'server_port':u.port,'password':unquote(u.username),'tls':{'enabled':True,'server_name':q['sni'][0]}}
if mode.endswith('reality'):
    assert q['security']==['reality']
    out['tls'].update(utls={'enabled':True,'fingerprint':q['fp'][0]},reality={'enabled':True,'public_key':q['pbk'][0],'short_id':q['sid'][0]})
else:
    assert q['type']==['ws'] and q['security']==['tls']
    out['tls']['certificate_path']=sys.argv[3]
    out['transport']={'type':'ws','path':q['path'][0],'headers':{'Host':q['host'][0]}}
with open(sys.argv[4],'w') as f: json.dump(out,f)
PY
  fi
  jq -n --argjson port "$client_port" --slurpfile out "$T/outbound.json" '{inbounds:[{type:"socks",listen:"127.0.0.1",listen_port:$port}],outbounds:[$out[0]],route:{final:"proxy"}}' >"$T/client.json"
  "$REAL_BIN" run -c "$CONFIG_FILE" >"$T/server.log" 2>&1 & server_pid=$!
  "$REAL_BIN" run -c "$T/client.json" >"$T/client.log" 2>&1 & client_pid=$!
  success=0
  for _ in {1..40}; do
    if output=$(curl -fsS --max-time 2 --noproxy '' --proxy "socks5h://127.0.0.1:$client_port" "http://127.0.0.1:$http_port/" 2>/dev/null); then
      [[ $output == extra-ok ]]; success=1; break
    fi
    sleep 0.1
  done
  if (( ! success )); then cat "$T/server.log" "$T/client.log" "$T/tls.log" >&2; exit 1; fi
  printf 'real %s share fields passed.\n' "$mode"
  kill "$server_pid" "$client_pid"; wait "$server_pid" "$client_pid" 2>/dev/null || true
  unset server_pid client_pid
done
