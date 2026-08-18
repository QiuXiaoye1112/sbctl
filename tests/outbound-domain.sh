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
    {type:\"socks\",tag:\"plain-test\",listen:\"127.0.0.1\",listen_port:18081,users:[]},
    {type:\"socks\",tag:\"order-test\",listen:\"127.0.0.1\",listen_port:18082,users:[]},
    {type:\"socks\",tag:\"preserve-test\",listen:\"127.0.0.1\",listen_port:18083,users:[]},
    {type:\"socks\",tag:\"tail-test\",listen:\"127.0.0.1\",listen_port:18084,users:[]},
    {type:\"socks\",tag:\"tail-test-2\",listen:\"127.0.0.1\",listen_port:18085,users:[]},
    {type:\"socks\",tag:\"dual-test\",listen:\"127.0.0.1\",listen_port:18086,users:[]},
    {type:\"socks\",tag:\"dual-test-2\",listen:\"127.0.0.1\",listen_port:18087,users:[]},
    {type:\"socks\",tag:\"compact-test\",listen:\"127.0.0.1\",listen_port:18088,users:[]},
    {type:\"socks\",tag:\"legend-test\",listen:\"127.0.0.1\",listen_port:18089,users:[]}
  ] | .outbounds += [
    {type:\"socks\",tag:\"socks-A\",server:\"127.0.0.1\",server_port:1080,version:\"5\"},
    {type:\"socks\",tag:\"socks-B\",server:\"127.0.0.1\",server_port:1081,version:\"5\"},
    {type:\"http\",tag:\"http-A\",server:\"127.0.0.1\",server_port:8080}
  ]" "$CONFIG_FILE" >"$tmp"
mv "$tmp" "$CONFIG_FILE"

tmp=$(temp_file)
jq '.route.rules += [
  {inbound:["order-test"],domain:["example.com"],action:"route",outbound:"socks-A"},
  {domain_keyword:["order-custom-x"],action:"route",outbound:"direct"},
  {inbound:["order-test"],domain_suffix:["example.com"],action:"route",outbound:"socks-A"},
  {domain_keyword:["order-custom-y"],action:"route",outbound:"direct"},
  {inbound:["order-test"],action:"route",outbound:"socks-A"}
]' "$CONFIG_FILE" >"$tmp"
mv "$tmp" "$CONFIG_FILE"

tmp=$(temp_file)
jq '.route.rules += [
  {inbound:["preserve-test"],domain:["a.example.com"],action:"route",outbound:"socks-A"},
  {inbound:["preserve-test"],domain:["a.example.com"],action:"route",outbound:"socks-A"},
  {domain_keyword:["preserve-custom-x"],action:"route",outbound:"direct"},
  {inbound:["preserve-test"],domain_suffix:["example.com"],action:"route",outbound:"socks-A"},
  {domain_keyword:["preserve-custom-y"],action:"route",outbound:"direct"},
  {inbound:["preserve-test"],action:"route",outbound:"socks-A"}
]' "$CONFIG_FILE" >"$tmp"
mv "$tmp" "$CONFIG_FILE"

add_domain_rule preserve-test exact a.example.com socks-B
add_domain_rule preserve-test suffix example.com socks-B
assign_outbound preserve-test socks-B
jq -e '
  .route.rules as $rules |
  [$rules[] |
    if .inbound==["preserve-test"] and .domain==["a.example.com"] then "A"
    elif .domain_keyword==["preserve-custom-x"] then "X"
    elif .inbound==["preserve-test"] and .domain_suffix==["example.com"] then "B"
    elif .domain_keyword==["preserve-custom-y"] then "Y"
    elif .inbound==["preserve-test"] and .action=="route" and .outbound=="socks-B" and
      ((keys_unsorted|sort)==["action","inbound","outbound"]) then "D"
    else empty
    end] == ["A","A","X","B","Y","D"] and
  ([$rules[] | select(.inbound==["preserve-test"] and .domain==["a.example.com"])] | length == 2) and
  ([$rules[] | select(.inbound==["preserve-test"] and .domain_suffix==["example.com"])] | length == 1)
' "$CONFIG_FILE" >/dev/null

add_domain_rule order-test suffix api.example.com socks-A
assign_outbound order-test socks-B
jq -e '
  .route.rules as $rules |
  ([$rules[] | .inbound==["order-test"] and .domain==["example.com"]] | index(true)) as $exact |
  ([$rules[] | .inbound==["order-test"] and .domain_suffix==["api.example.com"]] | index(true)) as $specific |
  ([$rules[] | .inbound==["order-test"] and .domain_suffix==["example.com"]] | index(true)) as $broad |
  ([$rules[] | .inbound==["order-test"] and .action=="route" and .outbound=="socks-B" and ((keys_unsorted|sort)==["action","inbound","outbound"])] | index(true)) as $default |
  ([$rules[] | .domain_keyword==["order-custom-x"]] | index(true)) as $custom_x |
  ([$rules[] | .domain_keyword==["order-custom-y"]] | index(true)) as $custom_y |
  ($exact < $custom_x and $custom_x < $specific and $specific < $broad and
    $broad < $custom_y and $custom_y < $default)
' "$CONFIG_FILE" >/dev/null

# A suffix appended after the only existing managed rule must not be dropped
# when the calculated insertion index equals the current rule-list length.
add_domain_rule tail-test exact tail.example.com socks-A
add_domain_rule tail-test suffix example.com socks-B
add_domain_rule tail-test-2 exact tail.example.com socks-A
add_domain_rule tail-test-2 suffix example.com socks-B
jq -e '
  .route.rules |
  any(.[]; .inbound==["tail-test"] and .domain==["tail.example.com"] and .outbound=="socks-A") and
  any(.[]; .inbound==["tail-test"] and .domain_suffix==["example.com"] and .outbound=="socks-B") and
  any(.[]; .inbound==["tail-test-2"] and .domain_suffix==["example.com"] and .outbound=="socks-B")
' "$CONFIG_FILE" >/dev/null

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

  before=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
  add_domain_rule in-test suffix openai.com socks-B
  after=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
  [[ $before == "$after" ]]
  jq -e '[.route.rules[] | select(.inbound==["in-test"] and .domain_suffix==["openai.com"])] | length == 1 and .[0].outbound == "socks-A"' "$CONFIG_FILE" >/dev/null
  jq -e '[.route.rules[] | select(.inbound==["in-test"] and .domain==["openai.com"])] | length == 1' "$CONFIG_FILE" >/dev/null

  confirm() { return 0; }
  delete_domain_rule in-test <<< '1,2'
  jq -e '.route.rules | all(.[]; (.domain // []) != ["openai.com"] and (.domain_suffix // []) != ["openai.com"]) and any(.[]; .action=="route" and .inbound==["in-test"] and .outbound=="socks-B")' "$CONFIG_FILE" >/dev/null

  add_domain_rule in-test exact api.test.com direct
  jq -e '.route.rules | any(.[]; .inbound==["in-test"] and .domain==["api.test.com"] and .outbound=="direct")' "$CONFIG_FILE" >/dev/null

  add_domain_rule in-test suffix "batch-one.test, BATCH-TWO.TEST ,batch-three.test" socks-A
  jq -e '
    [.route.rules[] | select(.inbound==["in-test"] and
      (.domain_suffix[0] | IN("batch-one.test", "batch-two.test", "batch-three.test")))] |
    map(.domain_suffix[0]) | sort == ["batch-one.test", "batch-three.test", "batch-two.test"]
  ' "$CONFIG_FILE" >/dev/null

  before=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
  add_domain_rule in-test suffix batch-one.test,batch-four.test socks-B
  after=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
  [[ $before == "$after" ]]
  jq -e '
    [.route.rules[] | select(.inbound==["in-test"] and .domain_suffix==["batch-one.test"])] |
    length == 1 and .[0].outbound == "socks-A"
  ' "$CONFIG_FILE" >/dev/null
  jq -e '
    [.route.rules[] | select(.inbound==["in-test"] and .domain_suffix==["batch-four.test"])] | length == 0
  ' "$CONFIG_FILE" >/dev/null

  local_tag=$(_ensure_local_outbound 2001:db8::1234)
  add_domain_rule in-test suffix ipv6.test.com "$local_tag"
  jq -e --arg tag "$local_tag" '.outbounds | any(.[]; .tag==$tag and .type=="direct" and .inet6_bind_address=="2001:db8::1234" and .domain_resolver=={"server":"sbctl-local-dns","strategy":"ipv6_only"})' "$CONFIG_FILE" >/dev/null
  jq -e '.dns.servers | any(.[]; .tag=="sbctl-local-dns" and .type=="local")' "$CONFIG_FILE" >/dev/null
  jq -e --arg tag "$local_tag" '.route.rules | any(.[]; .domain_suffix==["ipv6.test.com"] and .outbound==$tag)' "$CONFIG_FILE" >/dev/null
  listing=$(list_domain_rules in-test)
  grep -Fq '入站：in-test' <<<"$listing"
  grep -Fq '精确 → direct' <<<"$listing"
  grep -Fq 'ipv6.test.com' <<<"$listing"
  grep -Fq '2001:db8::1234' <<<"$listing"

  add_domain_rule compact-test suffix zeta-compact.test socks-A >/dev/null
  add_domain_rule compact-test suffix alpha-compact.test socks-A >/dev/null
  compact_listing=$(list_domain_rules compact-test)
  grep -Fq '入站：compact-test' <<<"$compact_listing"
  grep -Fq '子域名 → socks-A' <<<"$compact_listing"
  [[ $(grep -Fc '子域名' <<<"$compact_listing") == 1 ]]
  [[ $(grep -Fc 'socks-A' <<<"$compact_listing") == 1 ]]
  compact_alpha_line=$(grep -nF 'alpha-compact.test' <<<"$compact_listing" | cut -d: -f1)
  compact_zeta_line=$(grep -nF 'zeta-compact.test' <<<"$compact_listing" | cut -d: -f1)
  ((compact_alpha_line < compact_zeta_line))

  add_domain_rule legend-test suffix zeta-legend.test socks-A >/dev/null
  add_domain_rule legend-test suffix alpha-legend.test direct >/dev/null
  add_domain_rule legend-test suffix middle-legend.test socks-A >/dev/null
  legend_listing=$(list_domain_rules legend-test)
  grep -Fq '子域名 → direct' <<<"$legend_listing"
  grep -Fq '子域名 → socks-A' <<<"$legend_listing"
  [[ $(grep -Fc 'socks-A' <<<"$legend_listing") == 1 ]]
  legend_alpha_line=$(grep -nF 'alpha-legend.test' <<<"$legend_listing" | cut -d: -f1)
  legend_middle_line=$(grep -nF 'middle-legend.test' <<<"$legend_listing" | cut -d: -f1)
  legend_zeta_line=$(grep -nF 'zeta-legend.test' <<<"$legend_listing" | cut -d: -f1)
  ((legend_alpha_line < legend_middle_line && legend_middle_line < legend_zeta_line))
  delete_domain_rule legend-test <<< '1'
  jq -e '
    [.route.rules[] | select(.inbound==["legend-test"])] |
    all(.[]; (.domain_suffix // []) != ["alpha-legend.test"]) and
    any(.[]; .domain_suffix==["middle-legend.test"]) and
    any(.[]; .domain_suffix==["zeta-legend.test"])
  ' "$CONFIG_FILE" >/dev/null

  add_domain_rule in-test suffix zeta-sort.test socks-A >/dev/null
  add_domain_rule in-test suffix alpha-sort.test socks-A >/dev/null
  add_domain_rule in-test suffix middle-sort.test socks-A >/dev/null
  route_order_before=$(jq -c '
    [.route.rules[] |
      select(.inbound==["in-test"] and
        (.domain_suffix[0] | IN("zeta-sort.test", "alpha-sort.test", "middle-sort.test"))) |
      .domain_suffix[0]]
  ' "$CONFIG_FILE")
  before=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
  listing=$(list_domain_rules in-test)
  after=$(sha256sum "$CONFIG_FILE" | awk '{print $1}')
  [[ $before == "$after" ]]
  route_order_after=$(jq -c '
    [.route.rules[] |
      select(.inbound==["in-test"] and
        (.domain_suffix[0] | IN("zeta-sort.test", "alpha-sort.test", "middle-sort.test"))) |
      .domain_suffix[0]]
  ' "$CONFIG_FILE")
  [[ $route_order_before == "$route_order_after" ]]
  alpha_line=$(grep -nF 'alpha-sort.test' <<<"$listing" | cut -d: -f1)
  middle_line=$(grep -nF 'middle-sort.test' <<<"$listing" | cut -d: -f1)
  zeta_line=$(grep -nF 'zeta-sort.test' <<<"$listing" | cut -d: -f1)
  ((alpha_line < middle_line && middle_line < zeta_line))

  local_v4_tag=$(_ensure_local_outbound 192.0.2.123)
  jq -e --arg tag "$local_v4_tag" '.outbounds | any(.[]; .tag==$tag and .type=="direct" and .inet4_bind_address=="192.0.2.123" and .domain_resolver=={"server":"sbctl-local-dns","strategy":"ipv4_only"})' "$CONFIG_FILE" >/dev/null

  tmp=$(temp_file)
  jq --arg tag "$local_tag" '(.outbounds[] | select(.tag==$tag)).domain_resolver = null' "$CONFIG_FILE" >"$tmp"
  mv "$tmp" "$CONFIG_FILE"
  [[ $(_ensure_local_outbound 2001:db8::1234) == "$local_tag" ]]
  jq -e --arg tag "$local_tag" '.outbounds | any(.[]; .tag==$tag and .domain_resolver=={"server":"sbctl-local-dns","strategy":"ipv6_only"})' "$CONFIG_FILE" >/dev/null

  # IPv6 selection alone remains a pure IPv6 outbound; only an explicit
  # fallback choice creates a dual-stack outbound.
  detect_local_ips() {
    printf '%s\t%s\t%s\n' '192.0.2.123 (IPv4)' 192.0.2.123 eth0
    printf '%s\t%s\t%s\n' '198.51.100.9 (IPv4)' 198.51.100.9 eth1
    printf '%s\t%s\t%s\n' '2001:db8::1234 (IPv6)' 2001:db8::1234 eth0
  }
  original_choose=$(declare -f choose)
  original_sing_box_version=$(declare -f sing_box_version)
  choose_prompts=()
  desired_top=''
  desired_fallback=1
  choose() {
    local __var=$1 prompt=$2; shift 2
    local -a options=("$@")
    choose_prompts+=("$prompt")
    if [[ $prompt == '选择出站' ]]; then
      local i
      for ((i=0; i<${#options[@]}; i++)); do
        [[ ${options[$i]} == "$desired_top" ]] || continue
        printf -v "$__var" '%s' "$((i+1))"
        return 0
      done
      return 1
    fi
    if [[ $prompt == 'IPv4 回退' ]]; then
      printf -v "$__var" '%s' "$desired_fallback"
      return 0
    fi
    return 1
  }

  desired_top=direct
  choose_prompts=()
  select_outbound choice_outbound 1
  [[ $choice_outbound == direct ]]
  ! printf '%s\n' "${choose_prompts[@]}" | grep -Fxq 'IPv4 回退'

  desired_top='192.0.2.123 (IPv4)'
  choose_prompts=()
  select_outbound choice_outbound 1
  [[ $choice_outbound == local-192-0-2-123 ]]
  ! printf '%s\n' "${choose_prompts[@]}" | grep -Fxq 'IPv4 回退'
  jq -e --arg tag "$choice_outbound" '.outbounds | any(.[]; .tag==$tag and has("inet4_bind_address") and (.inet6_bind_address|not) and (.domain_strategy|not) and (.fallback_delay|not))' "$CONFIG_FILE" >/dev/null

  desired_top='socks-A (socks · 127.0.0.1:1080)'
  choose_prompts=()
  select_outbound choice_outbound 1
  [[ $choice_outbound == socks-A ]]
  ! printf '%s\n' "${choose_prompts[@]}" | grep -Fxq 'IPv4 回退'

  desired_top='http-A (http · 127.0.0.1:8080)'
  choose_prompts=()
  select_outbound choice_outbound 1
  [[ $choice_outbound == http-A ]]
  ! printf '%s\n' "${choose_prompts[@]}" | grep -Fxq 'IPv4 回退'

  desired_top='2001:db8::1234 (IPv6)'
  desired_fallback=1
  choose_prompts=()
  select_outbound choice_outbound 1
  [[ $choice_outbound == local-2001-db8--1234 ]]
  grep -Fxq 'IPv4 回退' <<<"${choose_prompts[*]}"
  jq -e --arg tag "$choice_outbound" '.outbounds | any(.[]; .tag==$tag and has("inet6_bind_address") and (.inet4_bind_address|not) and (.domain_strategy|not) and (.fallback_delay|not))' "$CONFIG_FILE" >/dev/null

  desired_fallback=2
  choose_prompts=()
  select_outbound choice_outbound 1
  dual_tag=$choice_outbound
  [[ $dual_tag == local-prefer6-* ]]
  jq -e --arg tag "$dual_tag" '.outbounds | any(.[]; .tag==$tag and .type=="direct" and .inet6_bind_address=="2001:db8::1234" and .inet4_bind_address=="192.0.2.123" and .domain_resolver=={"server":"sbctl-local-dns","strategy":"prefer_ipv6"} and .fallback_delay=="300ms" and (.domain_strategy|not))' "$CONFIG_FILE" >/dev/null
  [[ $(_outbound_display_name "$dual_tag") == '2001:...:1234 → 192.0.2.123' ]]
  [[ $(_outbound_endpoint_display 2001:db8:1700::1234 5000) == '[2001:...:1234]:5000' ]]
  [[ $(_outbound_endpoint_display 192.0.2.123 5000) == '192.0.2.123:5000' ]]
  [[ $(_ensure_prefer_ipv6_outbound 2001:db8::1234 192.0.2.123) == "$dual_tag" ]]
  [[ $(jq '[.outbounds[] | select(.tag|startswith("local-prefer6-"))] | length' "$CONFIG_FILE") == 1 ]]

  pair_b_tag=$(_ensure_prefer_ipv6_outbound 2001:db8::1234 198.51.100.9)
  [[ $pair_b_tag != "$dual_tag" ]]
  [[ $(_ensure_prefer_ipv6_outbound 2001:db8::1234 198.51.100.9) == "$pair_b_tag" ]]
  [[ $(jq '[.outbounds[] | select(.tag|startswith("local-prefer6-"))] | length' "$CONFIG_FILE") == 2 ]]

  add_domain_rule dual-test exact fallback.example.com "$dual_tag"
  add_domain_rule dual-test-2 exact fallback.example.com "$pair_b_tag"
  assign_outbound dual-test "$dual_tag"
  jq -e --arg tag "$dual_tag" '
    .route.rules | any(.[]; .inbound==["dual-test"] and .domain==["fallback.example.com"] and .outbound==$tag) and
    any(.[]; .inbound==["dual-test"] and .action=="route" and .outbound==$tag and ((keys_unsorted|sort)==["action","inbound","outbound"]))
  ' "$CONFIG_FILE" >/dev/null
  jq -e --arg tag "$pair_b_tag" '.route.rules | any(.[]; .inbound==["dual-test-2"] and .domain==["fallback.example.com"] and .outbound==$tag)' "$CONFIG_FILE" >/dev/null

  preserve_before_dual=$(jq -c '
    [.route.rules[] |
      if .inbound==["preserve-test"] and .domain==["a.example.com"] then "A"
      elif .domain_keyword==["preserve-custom-x"] then "X"
      elif .inbound==["preserve-test"] and .domain_suffix==["example.com"] then "B"
      elif .domain_keyword==["preserve-custom-y"] then "Y"
      elif .inbound==["preserve-test"] and .action=="route" and ((keys_unsorted|sort)==["action","inbound","outbound"]) then "D"
      else empty
      end]' "$CONFIG_FILE")
  assign_outbound preserve-test "$dual_tag"
  [[ $preserve_before_dual == "$(jq -c '
    [.route.rules[] |
      if .inbound==["preserve-test"] and .domain==["a.example.com"] then "A"
      elif .domain_keyword==["preserve-custom-x"] then "X"
      elif .inbound==["preserve-test"] and .domain_suffix==["example.com"] then "B"
      elif .domain_keyword==["preserve-custom-y"] then "Y"
      elif .inbound==["preserve-test"] and .action=="route" and ((keys_unsorted|sort)==["action","inbound","outbound"]) then "D"
      else empty
      end]' "$CONFIG_FILE")" ]]

  # Schema-generation guard only: a mocked version string is not evidence of
  # sing-box 1.14 compatibility. A real 1.14 binary must be added to CI before
  # support is claimed.
  sing_box_version() { printf '1.14.0'; }
  modern_tag=$(_ensure_prefer_ipv6_outbound 2001:db8::5678 192.0.2.123)
  jq -e --arg tag "$modern_tag" '.outbounds | any(.[]; .tag==$tag and .domain_resolver=={"server":"sbctl-local-dns","strategy":"prefer_ipv6"} and .fallback_delay=="300ms" and (.domain_strategy|not))' "$CONFIG_FILE" >/dev/null

  detect_local_ips() {
    printf '%s\t%s\t%s\n' '2001:db8::1234 (IPv6)' 2001:db8::1234 eth0
  }
  desired_top='2001:db8::1234 (IPv6)'
  choose_prompts=()
  select_outbound choice_outbound 1
  [[ $choice_outbound == local-2001-db8--1234 ]]
  ! printf '%s\n' "${choose_prompts[@]}" | grep -Fxq 'IPv4 回退'

  eval "$original_sing_box_version"
  eval "$original_choose"

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

if [[ -n ${SBCTL_REAL_SING_BOX_BIN:-} ]]; then
  [[ -x $SBCTL_REAL_SING_BOX_BIN ]] || { printf 'SBCTL_REAL_SING_BOX_BIN is not executable\n' >&2; exit 1; }
  expected_series=${SBCTL_EXPECT_SING_BOX_SERIES:-1.13}
  real_version=$($SBCTL_REAL_SING_BOX_BIN version | sed -nE '1s/^sing-box version ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')
  [[ $real_version == "$expected_series".* ]] || {
    printf 'expected real sing-box %s.x, got %s\n' "$expected_series" "${real_version:-unknown}" >&2
    exit 1
  }
  real_config="$MOCK/real-fallback-check.json"
  jq -n --argjson outbound "$(jq -c --arg tag "$dual_tag" '.outbounds[] | select(.tag==$tag)' "$CONFIG_FILE")" '
    {
      log:{level:"warn"},
      dns:{servers:[{type:"local",tag:"sbctl-local-dns"}]},
      inbounds:[{type:"socks",tag:"check-in",listen:"127.0.0.1",listen_port:19080}],
      outbounds:[$outbound],
      route:{final:$outbound.tag}
    }
  ' >"$real_config"
  "$SBCTL_REAL_SING_BOX_BIN" check -c "$real_config"
  printf 'real sing-box %s fallback config check passed.\n' "$real_version"
fi
printf 'sbctl outbound domain tests passed.\n'
