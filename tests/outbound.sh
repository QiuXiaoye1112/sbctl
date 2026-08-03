#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
MOCK=$(mktemp -d)
trap 'rm -rf "$MOCK"' EXIT
cat >"$MOCK/sing-box" <<'SH'
#!/usr/bin/env bash
set -e
case ${1-} in
  version) echo 'sing-box version 1.13.15';;
  check) jq -e . "$3" >/dev/null;;
  *) exit 1;;
esac
SH
chmod +x "$MOCK/sing-box"
CASE="$MOCK/case"
mkdir -p "$CASE"
PATH="$MOCK:$PATH" \
SBCTL_SING_BOX_BIN="$MOCK/sing-box" \
SBCTL_CONFIG_DIR="$CASE/cfg" \
SBCTL_CONFIG_FILE="$CASE/cfg/config.json" \
SBCTL_META_FILE="$CASE/meta.json" \
SBCTL_CERT_DIR="$CASE/certs" \
SBCTL_LOCK_FILE="$CASE/lock" \
bash -c '
  set -Eeuo pipefail
  source ./sbctl.sh
  write_default_config
  tmp=$(temp_file)
  jq ".inbounds += [{type:\"socks\",tag:\"in-test\",listen:\"127.0.0.1\",listen_port:18080,users:[]}]" "$CONFIG_FILE" >"$tmp"
  mv "$tmp" "$CONFIG_FILE"
  add_outbound <<EOF2
1
socks-out-test
127.0.0.1
1080
2
alice
secret
EOF2
  jq -e ".outbounds[]|select(.tag==\"socks-out-test\" and .type==\"socks\" and .server_port==1080)" "$CONFIG_FILE" >/dev/null
  assign_outbound in-test socks-out-test
  jq -e ".route.rules[]|select(.inbound==[\"in-test\"] and .action==\"route\" and .outbound==\"socks-out-test\")" "$CONFIG_FILE" >/dev/null
  [[ $(current_outbound_for_inbound in-test) == socks-out-test ]]
  confirm(){ return 0; }
  delete_outbound socks-out-test
  ! jq -e ".outbounds[]?|select(.tag==\"socks-out-test\")" "$CONFIG_FILE" >/dev/null
  [[ $(current_outbound_for_inbound in-test) == direct ]]
'
printf 'sbctl outbound tests passed.\n'
