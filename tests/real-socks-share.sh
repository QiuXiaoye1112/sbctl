#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REAL_BIN=${SBCTL_REAL_SING_BOX_BIN:-sing-box}
command -v "$REAL_BIN" >/dev/null || { printf "set SBCTL_REAL_SING_BOX_BIN to a sing-box executable\n" >&2; exit 1; }
T=$(mktemp -d)
trap 'kill ${server_pid:-} ${core_pid:-} 2>/dev/null || true; rm -rf "$T"' EXIT
export SBCTL_TESTING=1 SBCTL_CONFIG_DIR="$T/config" SBCTL_CONFIG_FILE="$T/config/config.json" SBCTL_META_FILE="$T/meta.json" SBCTL_CERT_DIR="$T/config/certs" SBCTL_LOCK_FILE="$T/lock"
source ./sbctl.sh
mkdir -p "$CONFIG_DIR"
IFS=" " read -r proxy_port http_port < <(python3 -c 'import socket; a=socket.socket(); b=socket.socket(); a.bind(("127.0.0.1",0)); b.bind(("127.0.0.1",0)); print(a.getsockname()[1],b.getsockname()[1])')
printf '%s\n' '{"inbounds":{"test":{"host":"127.0.0.1"}}}' >"$META_FILE"
printf 'sbctl-real-ok\n' >"$T/index.html"
python3 -m http.server "$http_port" --bind 127.0.0.1 --directory "$T" >"$T/http.log" 2>&1 & server_pid=$!
for scenario in socks-auth socks-anonymous http-auth http-anonymous; do
  protocol=${scenario%%-*}
  users='[]'
  [[ $scenario == *-auth ]] && users='[{"username":"user","password":"secret"}]'
  jq -n --arg type "$protocol" --argjson p "$proxy_port" --argjson users "$users" '{inbounds:[{type:$type,tag:"test",listen:"127.0.0.1",listen_port:$p,users:$users}],outbounds:[{type:"direct",tag:"direct"}],route:{final:"direct"}}' >"$CONFIG_FILE"
  "$REAL_BIN" run -c "$CONFIG_FILE" >"$T/core.log" 2>&1 & core_pid=$!
  link=$(print_share test | sed -n 's/^链接: //p')
  passed=false
  for attempt in {1..30}; do
    if output=$(curl --silent --show-error --fail --max-time 2 --noproxy '' --proxy "${link%%#*}" "http://127.0.0.1:$http_port/" 2>/dev/null); then
      [[ $output == sbctl-real-ok ]]
      passed=true
      break
    fi
    sleep 0.1
  done
  if [[ $passed != true ]]; then
    cat "$T/core.log" "$T/http.log" >&2
    exit 1
  fi
  kill "$core_pid"
  wait "$core_pid" || true
  core_pid=
  printf 'real sing-box %s share via curl passed.\n' "$scenario"
done
