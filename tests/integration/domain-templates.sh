#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
MOCK=$(mktemp -d)
trap 'rm -rf "$MOCK"' EXIT

if [[ -z ${SBCTL_REAL_SING_BOX_BIN:-} ]]; then
cat >"$MOCK/sing-box" <<'SH'
#!/usr/bin/env bash
case ${1-} in
  version) printf '%s\n' 'sing-box version 1.13.15';;
  check) jq -e . "$3" >/dev/null;;
  *) exit 1;;
esac
SH
chmod +x "$MOCK/sing-box"
TEST_SING_BOX_BIN="$MOCK/sing-box"
else
  [[ -x $SBCTL_REAL_SING_BOX_BIN ]]
  TEST_SING_BOX_BIN=$SBCTL_REAL_SING_BOX_BIN
fi

export PATH="$MOCK:$PATH"
export SBCTL_TESTING=1
export SBCTL_SING_BOX_BIN="$TEST_SING_BOX_BIN"
export SBCTL_CONFIG_DIR="$MOCK/config"
export SBCTL_CONFIG_FILE="$MOCK/config/config.json"
export SBCTL_META_FILE="$MOCK/meta.json"
export SBCTL_CERT_DIR="$MOCK/certs"
export SBCTL_LOCK_FILE="$MOCK/lock"

source "$ROOT/sbctl.sh"
trap - ERR

mkdir -p "$SBCTL_CONFIG_DIR"
cat >"$SBCTL_CONFIG_FILE" <<'JSON'
{
  "log":{"level":"warn"},
  "inbounds":[
    {"type":"socks","tag":"in-one","listen":"127.0.0.1","listen_port":18080,"users":[]},
    {"type":"socks","tag":"in-two","listen":"127.0.0.1","listen_port":18081,"users":[]}
  ],
  "outbounds":[
    {"type":"direct","tag":"direct"},
    {"type":"socks","tag":"proxy-us","server":"192.0.2.10","server_port":1080,"version":"5"}
  ],
  "route":{"rules":[],"final":"direct"}
}
JSON

# Existing metadata is upgraded without losing content.
printf '%s\n' '{"schema":2,"inbounds":{"in-one":{"host":"example.com"}},"certificates":{},"managedResources":{},"migrations":{}}' >"$SBCTL_META_FILE"
init_meta
jq -e '.domainTemplates=={"templates":[],"bindings":[],"managed":[]} and .inbounds["in-one"].host=="example.com"' "$SBCTL_META_FILE" >/dev/null

commit_metadata_mutation _meta_template_add OpenAI
add_domain_template_domains OpenAI suffix openai.com >/dev/null
apply_domain_template in-one OpenAI proxy-us >/dev/null
apply_domain_template in-two OpenAI proxy-us >/dev/null

jq -e '[.route.rules[] | select(.domain_suffix==["openai.com"])] | length==2' "$CONFIG_FILE" >/dev/null
jq -e '[.domainTemplates.managed[] | select(.match=="suffix" and .domain=="openai.com")] | length==2' "$META_FILE" >/dev/null
jq -e '[.domainTemplates.bindings[] | select(.template=="OpenAI")] | length==2' "$META_FILE" >/dev/null
menu_rules=$(list_domain_rules in-one --menu)
[[ $menu_rules != *openai.com* ]]

update_domain_template_outbound in-one OpenAI direct >/dev/null
jq -e 'any(.route.rules[]; .inbound==["in-one"] and .domain_suffix==["openai.com"] and .outbound=="direct") and
       any(.route.rules[]; .inbound==["in-two"] and .domain_suffix==["openai.com"] and .outbound=="proxy-us")' "$CONFIG_FILE" >/dev/null

# A direct rule wins over template coverage and survives template edits.
add_domain_rule in-one exact direct.example.com direct >/dev/null
add_domain_template_domains OpenAI exact direct.example.com >/dev/null
jq -e '[.route.rules[] | select(.inbound==["in-one"] and .domain==["direct.example.com"])] | length==1' "$CONFIG_FILE" >/dev/null
jq -e 'all(.domainTemplates.managed[]; .inbound!="in-one" or .domain!="direct.example.com")' "$META_FILE" >/dev/null
delete_domain_template_domains OpenAI exact direct.example.com >/dev/null
jq -e 'any(.route.rules[]; .inbound==["in-one"] and .domain==["direct.example.com"])' "$CONFIG_FILE" >/dev/null

# Later bindings override earlier ones; removing one restores the fallback.
commit_metadata_mutation _meta_template_add Second
add_domain_template_domains Second suffix openai.com >/dev/null
apply_domain_template in-one Second proxy-us >/dev/null
jq -e '[.route.rules[] | select(.inbound==["in-one"] and .domain_suffix==["openai.com"])] |
       length==1 and .[0].outbound=="proxy-us"' "$CONFIG_FILE" >/dev/null
remove_domain_template in-one Second >/dev/null
jq -e '[.route.rules[] | select(.inbound==["in-one"] and .domain_suffix==["openai.com"])] |
       length==1 and .[0].outbound=="direct"' "$CONFIG_FILE" >/dev/null

set +e
protected_output=$(delete_domain_rule in-one suffix openai.com 2>&1)
protected_status=$?
set -e
((protected_status != 0))
[[ $protected_output == *'由模板管理'* ]]

rename_inbound in-one renamed-one >/dev/null
jq -e 'any(.domainTemplates.bindings[]; .inbound=="renamed-one") and
       all(.domainTemplates.bindings[]; .inbound!="in-one")' "$META_FILE" >/dev/null
delete_inbound renamed-one 1 >/dev/null
jq -e 'all(.domainTemplates.bindings[]; .inbound!="renamed-one")' "$META_FILE" >/dev/null

confirm() { return 0; }
delete_outbound proxy-us >/dev/null
jq -e 'all(.domainTemplates.bindings[]; .outbound!="proxy-us")' "$META_FILE" >/dev/null

printf 'sbctl domain template tests passed.\n'
