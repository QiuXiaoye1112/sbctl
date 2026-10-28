#!/usr/bin/env bash
set -Eeuo pipefail
export SBCTL_TESTING=1
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
  before=$(cat "$CONFIG_FILE")
  if select_outbound selected 1 </dev/null >/dev/null 2>&1; then exit 1; fi
  [[ $(cat "$CONFIG_FILE") == "$before" ]]
  for input in "" $'"'"'1\n'"'"' $'"'"'1\ncancel-tag\n'"'"' $'"'"'1\ncancel-tag\n127.0.0.1\n'"'"' $'"'"'1\ncancel-tag\n127.0.0.1\n1080\n'"'"' $'"'"'1\ncancel-tag\n127.0.0.1\n1080\n2\n'"'"' $'"'"'1\ncancel-tag\n127.0.0.1\n1080\n2\nalice\n'"'"'; do
    if add_outbound <<<"$input" >/dev/null 2>&1; then exit 1; fi
    [[ $(cat "$CONFIG_FILE") == "$before" ]]
  done
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
  details=$(show_outbound_details socks-out-test)
  grep -Fq "\"server\": \"127.0.0.1\"" <<<"$details"
  grep -Fq "\"server_port\": 1080" <<<"$details"
  grep -Fq "\"username\": \"alice\"" <<<"$details"
  grep -Fq "\"password\": \"secret\"" <<<"$details"
  assign_outbound in-test socks-out-test
  jq -e ".route.rules[]|select(.inbound==[\"in-test\"] and .action==\"route\" and .outbound==\"socks-out-test\")" "$CONFIG_FILE" >/dev/null
  [[ $(current_outbound_for_inbound in-test) == socks-out-test ]]
  confirm(){ return 0; }
  jq ".route.final=\"socks-out-test\"" "$CONFIG_FILE" >"$tmp"; mv "$tmp" "$CONFIG_FILE"
  if delete_outbound socks-out-test; then exit 1; fi
  jq -e ".outbounds[]|select(.tag==\"socks-out-test\")" "$CONFIG_FILE" >/dev/null
  jq ".route.final=\"direct\" | .outbounds += [{type:\"direct\",tag:\"dependent\",detour:\"socks-out-test\"}]" "$CONFIG_FILE" >"$tmp"; mv "$tmp" "$CONFIG_FILE"
  if delete_outbound socks-out-test; then exit 1; fi
  jq "del(.outbounds[]|select(.tag==\"dependent\"))" "$CONFIG_FILE" >"$tmp"; mv "$tmp" "$CONFIG_FILE"
  jq ".dns.servers=[{tag:\"dns-test\",type:\"udp\",server:\"1.1.1.1\",detour:\"socks-out-test\"}]" "$CONFIG_FILE" >"$tmp"; mv "$tmp" "$CONFIG_FILE"
  if delete_outbound socks-out-test; then exit 1; fi
  jq "del(.dns) | .route.rule_set=[{type:\"remote\",tag:\"r\",url:\"https://example.com/r\",download_detour:\"socks-out-test\"}]" "$CONFIG_FILE" >"$tmp"; mv "$tmp" "$CONFIG_FILE"
  if delete_outbound socks-out-test; then exit 1; fi
  jq "del(.route.rule_set) | .route.rules += [{type:\"logical\",mode:\"or\",rules:[{domain:[\"example.com\"],outbound:\"socks-out-test\"}]}]" "$CONFIG_FILE" >"$tmp"; mv "$tmp" "$CONFIG_FILE"
  if delete_outbound socks-out-test; then exit 1; fi
  jq ".route.rules |= map(select(.type != \"logical\"))" "$CONFIG_FILE" >"$tmp"; mv "$tmp" "$CONFIG_FILE"
  delete_outbound socks-out-test
  ! jq -e ".outbounds[]?|select(.tag==\"socks-out-test\")" "$CONFIG_FILE" >/dev/null
  [[ $(current_outbound_for_inbound in-test) == direct ]]
'
printf 'sbctl outbound tests passed.\n'
