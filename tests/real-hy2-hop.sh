#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REAL_BIN=${SBCTL_REAL_SING_BOX_BIN:-sing-box}
command -v "$REAL_BIN" >/dev/null || { echo 'set SBCTL_REAL_SING_BOX_BIN' >&2; exit 1; }
if [[ ${1-} != --worker ]]; then
  exec unshare -nm bash "$0" --worker
fi
T=$(mktemp -d)
NS="sbctl-hop-$$"
trap 'kill ${http_pid:-} ${server_pid:-} ${client_pid:-} 2>/dev/null || true; ip netns del $NS 2>/dev/null || true; rm -rf "$T"' EXIT
mount --make-rshared /run/netns
ip netns add $NS
ip link add sbctl-server type veth peer name sbctl-client
ip link set sbctl-client netns $NS
ip addr add 10.203.0.1/24 dev sbctl-server
ip link set sbctl-server up
ip link set lo up
ip netns exec $NS ip addr add 10.203.0.2/24 dev sbctl-client
ip netns exec $NS ip link set sbctl-client up
ip netns exec $NS ip link set lo up
export SBCTL_TESTING=1 SBCTL_CONFIG_DIR="$T/config" SBCTL_CONFIG_FILE="$T/config/config.json" SBCTL_META_FILE="$T/meta.json" SBCTL_CERT_DIR="$T/config/certs" SBCTL_LOCK_FILE="$T/lock"
# shellcheck source=/dev/null
source ./sbctl.sh
mkdir -p "$CONFIG_DIR"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/key.pem" -out "$T/cert.pem" -days 1 -subj '/CN=example.test' -addext 'subjectAltName=DNS:example.test' >/dev/null 2>&1
jq -n --arg cert "$T/cert.pem" --arg key "$T/key.pem" '{inbounds:[{type:"hysteria2",tag:"test",listen:"0.0.0.0",listen_port:24443,users:[{name:"user",password:"test-password"}],tls:{enabled:true,server_name:"example.test",certificate_path:$cert,key_path:$key}}],outbounds:[{type:"direct",tag:"direct"}],route:{final:"direct"}}' >"$CONFIG_FILE"
printf '%s\n' '{"inbounds":{"test":{"host":"10.203.0.1","hysteria2PortHopping":{"enabled":true,"range":"30000-30009"}}}}' >"$META_FILE"
link=$(print_share test | sed -n 's/^链接: //p')
python3 - "$link" "$T/cert.pem" "$T/client.json" <<'PY'
import json,sys
from urllib.parse import urlsplit,parse_qs,unquote
u=urlsplit(sys.argv[1]); q=parse_qs(u.query)
assert u.scheme=='hysteria2' and u.netloc.endswith(':30000-30009')
host,ports=u.netloc.rsplit('@',1)[1].split(':')
out={'type':'hysteria2','tag':'proxy','server':host,'server_ports':[ports.replace('-',':')],'hop_interval':'5s','password':unquote(u.username),'tls':{'enabled':True,'server_name':q['sni'][0],'certificate_path':sys.argv[2]}}
config={'inbounds':[{'type':'socks','listen':'127.0.0.1','listen_port':24444}],'outbounds':[out],'route':{'final':'proxy'}}
with open(sys.argv[3],'w') as f: json.dump(config,f)
PY
hy2_hop_restore_all
printf 'hop-ok\n' >"$T/index.html"
python3 -m http.server 24445 --bind 10.203.0.1 --directory "$T" >"$T/http.log" 2>&1 & http_pid=$!
"$REAL_BIN" run -c "$CONFIG_FILE" >"$T/server.log" 2>&1 & server_pid=$!
ip netns exec $NS "$REAL_BIN" run -c "$T/client.json" >"$T/client.log" 2>&1 & client_pid=$!
for _ in {1..40}; do
  if output=$(ip netns exec $NS curl -fsS --max-time 2 --noproxy '' --proxy socks5h://127.0.0.1:24444 http://10.203.0.1:24445/ 2>/dev/null); then
    [[ $output == hop-ok ]]
    sleep 7
    output=$(ip netns exec $NS curl -fsS --max-time 5 --noproxy '' --proxy socks5h://127.0.0.1:24444 http://10.203.0.1:24445/)
    [[ $output == hop-ok ]]; echo 'real Hysteria2 hop NAT share fields passed.'; exit 0
  fi
  sleep 0.1
done
cat "$T/server.log" "$T/client.log" >&2
exit 1
