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
SBCTL_TESTING=1 \
SBCTL_SING_BOX_BIN="$MOCK/sing-box" \
SBCTL_CONFIG_DIR="$CASE/cfg" \
SBCTL_CONFIG_FILE="$CASE/cfg/config.json" \
SBCTL_META_FILE="$CASE/meta.json" \
SBCTL_CERT_DIR="$CASE/certs" \
SBCTL_LOCK_FILE="$CASE/lock" \
export PATH SBCTL_TESTING SBCTL_SING_BOX_BIN SBCTL_CONFIG_DIR SBCTL_CONFIG_FILE SBCTL_META_FILE SBCTL_CERT_DIR SBCTL_LOCK_FILE
source ./sbctl.sh
trap - ERR
write_default_config
  tmp=$(temp_file)
jq ".inbounds += [
    {type:\"socks\",tag:\"in-test\",listen:\"127.0.0.1\",listen_port:18080,users:[]},
    {type:\"socks\",tag:\"plain-test\",listen:\"127.0.0.1\",listen_port:18081,users:[]}
  ] | .outbounds += [
    {type:\"socks\",tag:\"socks-A\",server:\"127.0.0.1\",server_port:1080,version:\"5\"},
    {type:\"socks\",tag:\"socks-B\",server:\"127.0.0.1\",server_port:1081,version:\"5\"}
  ]" "$CONFIG_FILE" >"$tmp"
mv "$tmp" "$CONFIG_FILE"

add_domain_rule in-test suffix OPENAI.COM socks-A
  jq -e ".route.rules | any(.[]; .inbound==[\"in-test\"] and .domain_suffix==[\"openai.com\"] and .outbound==\"socks-A\")" "$CONFIG_FILE" >/dev/null

  add_domain_rule in-test exact openai.com socks-B
  jq -e ".route.rules | any(.[]; .inbound==[\"in-test\"] and .domain==[\"openai.com\"] and (.domain_suffix|not) and .outbound==\"socks-B\")" "$CONFIG_FILE" >/dev/null

  assign_outbound in-test socks-A
  jq -e '
    ([.route.rules[] | .inbound==["in-test"] and .domain_suffix==["openai.com"]] | index(true)) <
    ([.route.rules[] | .inbound==["in-test"] and .action=="route" and .outbound=="socks-A" and ((keys_unsorted|sort)==["action","inbound","outbound"])] | index(true))
  ' "$CONFIG_FILE" >/dev/null

  assign_outbound in-test socks-B
  jq -e '.route.rules | any(.[]; .inbound==["in-test"] and .domain_suffix==["openai.com"] and .outbound=="socks-A") and any(.[]; .inbound==["in-test"] and .action=="route" and .outbound=="socks-B" and ((keys_unsorted|sort)==["action","inbound","outbound"]))' "$CONFIG_FILE" >/dev/null

  add_domain_rule in-test suffix openai.com socks-B
  jq -e '[.route.rules[] | select(.inbound==["in-test"] and .domain_suffix==["openai.com"])] | length == 1 and .[0].outbound == "socks-B"' "$CONFIG_FILE" >/dev/null
  jq -e '[.route.rules[] | select(.inbound==["in-test"] and .domain==["openai.com"])] | length == 1' "$CONFIG_FILE" >/dev/null

  choose() { printf -v "$1" "%s" 1; }
  delete_domain_rule in-test
  jq -e '.route.rules | all(.[]; .domain_suffix != ["openai.com"]) and any(.[]; .domain==["openai.com"])' "$CONFIG_FILE" >/dev/null
  delete_domain_rule in-test
  jq -e '.route.rules | all(.[]; (.domain // []) != ["openai.com"]) and any(.[]; .action=="route" and .inbound==["in-test"] and .outbound=="socks-B")' "$CONFIG_FILE" >/dev/null

  add_domain_rule in-test exact api.test.com direct
  jq -e '.route.rules | any(.[]; .inbound==["in-test"] and .domain==["api.test.com"] and .outbound=="direct")' "$CONFIG_FILE" >/dev/null

  local_tag=$(_ensure_local_outbound 2001:db8::1234)
  add_domain_rule in-test suffix ipv6.test.com "$local_tag"
  jq -e --arg tag "$local_tag" '.outbounds | any(.[]; .tag==$tag and .type=="direct" and .inet6_bind_address=="2001:db8::1234")' "$CONFIG_FILE" >/dev/null
  jq -e --arg tag "$local_tag" '.route.rules | any(.[]; .domain_suffix==["ipv6.test.com"] and .outbound==$tag)' "$CONFIG_FILE" >/dev/null
  listing=$(list_domain_rules in-test)
  grep -Fq 'ipv6.test.com' <<<"$listing"
  grep -Fq '2001:db8::1234' <<<"$listing"

  add_domain_rule in-test suffix managed-delete.test socks-A
  confirm() { return 0; }
  delete_outbound socks-A
  jq -e '.outbounds | all(.[]; .tag != "socks-A")' "$CONFIG_FILE" >/dev/null
  jq -e '.route.rules | all(.[]; .domain_suffix != ["managed-delete.test"])' "$CONFIG_FILE" >/dev/null

  tmp=$(temp_file)
  jq ".outbounds += [{type:\"socks\",tag:\"socks-A\",server:\"127.0.0.1\",server_port:1080,version:\"5\"}] | .route.rules += [{network:[\"tcp\"],action:\"route\",outbound:\"socks-A\"}]" "$CONFIG_FILE" >"$tmp"
  mv "$tmp" "$CONFIG_FILE"
  add_domain_rule in-test suffix protected.test socks-A
  before=$(sha256sum "$CONFIG_FILE" | awk "{print \$1}")
  delete_outbound socks-A
  after=$(sha256sum "$CONFIG_FILE" | awk "{print \$1}")
  [[ $before == "$after" ]]
  jq -e '.outbounds | any(.[]; .tag=="socks-A")' "$CONFIG_FILE" >/dev/null
  jq -e '.route.rules | any(.[]; .network==["tcp"] and .outbound=="socks-A") and any(.[]; .domain_suffix==["protected.test"] and .outbound=="socks-A")' "$CONFIG_FILE" >/dev/null

  tmp=$(temp_file)
  jq ".route.rules |= map(select(.network != [\"tcp\"]))" "$CONFIG_FILE" >"$tmp"
  mv "$tmp" "$CONFIG_FILE"
  rename_inbound in-test renamed-test
  jq -e '.route.rules | all(.[]; ((.inbound // []) | index("in-test")) == null) and any(.[]; .inbound==["renamed-test"] and .domain_suffix==["protected.test"]) and any(.[]; .inbound==["renamed-test"] and .action=="route" and .outbound=="socks-B")' "$CONFIG_FILE" >/dev/null

  delete_inbound renamed-test 1
  jq -e '.inbounds | all(.[]; .tag != "renamed-test")' "$CONFIG_FILE" >/dev/null
  jq -e '.route.rules | all(.[]; ((.inbound // []) | index("renamed-test")) == null)' "$CONFIG_FILE" >/dev/null

  assign_outbound plain-test direct
  [[ $(current_outbound_for_inbound plain-test) == direct ]]
! jq -e '.route.rules[]? | select(.inbound==["plain-test"])' "$CONFIG_FILE" >/dev/null
printf 'sbctl outbound domain tests passed.\n'
