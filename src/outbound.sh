outbound_exists() {
  jq -e --arg tag "$1" '.outbounds[]?|select(.tag==$tag)' "$CONFIG_FILE" >/dev/null
}

_ifconfig_address_rows() {
  ifconfig 2>/dev/null | awk '
    /^[^[:space:]]/ {
      iface=$1
      sub(/:$/, "", iface)
    }
    {
      for (i=1; i<=NF; i++) {
        if ($i=="inet" || $i=="inet6") {
          family=($i=="inet" ? "4" : "6")
          address=$(i+1)
          if (address=="addr:") address=$(i+2)
          sub(/^addr:/, "", address)
          sub(/\/.*/, "", address)
          sub(/%.*/, "", address)
          print family "\t" address "\t" iface
          break
        }
      }
    }
  '
}

detect_local_ips() {
  local iface ip line
  if command_exists ip; then
    while IFS= read -r line; do
      iface=$(awk '{print $2}' <<<"$line")
      ip=$(awk '{print $4}' <<<"$line"); ip=${ip%/*}
      [[ $iface =~ ^(docker|br-|veth|virbr|lo|lxc|cali|flannel|cilium) ]] && continue
      validate_ipv4 "$ip" || continue
      [[ $ip =~ ^127\. ]] && continue
      printf '%s (IPv4)\t%s\t%s\n' "$ip" "$ip" "$iface"
    done < <(ip -o -4 addr show 2>/dev/null)
    while IFS= read -r line; do
      iface=$(awk '{print $2}' <<<"$line")
      ip=$(awk '{print $4}' <<<"$line"); ip=${ip%/*}
      ip=${ip%%%*}
      [[ $iface =~ ^(docker|br-|veth|virbr|lo|lxc|cali|flannel|cilium) ]] && continue
      [[ -z $ip || $ip == ::1 || $ip == fe80:* ]] && continue
      printf '%s (IPv6)\t%s\t%s\n' "$ip" "$ip" "$iface"
    done < <(ip -o -6 addr show 2>/dev/null)
  elif command_exists ifconfig; then
    local family
    while IFS=$'\t' read -r family ip iface; do
      [[ $iface =~ ^(docker|br-|veth|virbr|lo|lxc|cali|flannel|cilium) ]] && continue
      case $family in
        4)
          validate_ipv4 "$ip" || continue
          [[ $ip =~ ^127\. ]] && continue
          printf '%s (IPv4)\t%s\t%s\n' "$ip" "$ip" "$iface"
          ;;
        6)
          validate_ip_literal "$ip" && ! validate_ipv4 "$ip" || continue
          [[ $ip == ::1 || $ip == fe80:* ]] && continue
          printf '%s (IPv6)\t%s\t%s\n' "$ip" "$ip" "$iface"
          ;;
      esac
    done < <(_ifconfig_address_rows)
  fi
}

_local_tag_for_ip() {
  local ip=$1
  printf 'local-%s' "$(printf '%s' "$ip" | tr ':.' '-')"
}

_ensure_local_outbound() {
  local ip=$1 tag tmp bind_field domain_strategy dns_tag=sbctl-local-dns
  tag=$(_local_tag_for_ip "$ip")
  # sing-box uses inet4_bind_address / inet6_bind_address. Pair the bind
  # address with a strict resolver strategy so the other address family is
  # never used as a fallback.
  if [[ $ip == *:* ]]; then
    bind_field=inet6_bind_address
    domain_strategy=ipv6_only
  else
    bind_field=inet4_bind_address
    domain_strategy=ipv4_only
  fi

  if outbound_exists "$tag"; then
    # Upgrade local direct outbounds created before strict address-family
    # selection was added.
    if jq -e --arg tag "$tag" --arg dns_tag "$dns_tag" --arg strategy "$domain_strategy" '
      ([.dns.servers[]? | select(.tag==$dns_tag)] | length) == 0 or
      any(.outbounds[]?;
        .tag==$tag and .type=="direct" and
        (.domain_resolver.server != $dns_tag or
         .domain_resolver.strategy != $strategy or
         has("domain_strategy")))
    ' "$CONFIG_FILE" >/dev/null; then
      tmp=$(temp_file)
      jq --arg tag "$tag" --arg dns_tag "$dns_tag" --arg strategy "$domain_strategy" '
        .dns = (.dns // {}) |
        .dns.servers = (.dns.servers // []) |
        if any(.dns.servers[]?; .tag==$dns_tag) then .
        else .dns.servers += [{type:"local",tag:$dns_tag}]
        end |
        .outbounds |= map(
          if .tag==$tag and .type=="direct" then
            del(.domain_strategy) |
            .domain_resolver={server:$dns_tag,strategy:$strategy}
          else .
          end
        )' "$CONFIG_FILE" >"$tmp"
      if ! apply_candidate "$tmp" >/dev/null; then
        rm -f "$tmp"
        return 1
      fi
      rm -f "$tmp"
    fi
    printf '%s' "$tag"
    return 0
  fi

  tmp=$(temp_file)
  jq --arg tag "$tag" --arg ip "$ip" --arg field "$bind_field" --arg dns_tag "$dns_tag" --arg strategy "$domain_strategy" '
    .dns = (.dns // {}) |
    .dns.servers = (.dns.servers // []) |
    if any(.dns.servers[]?; .tag==$dns_tag) then .
    else .dns.servers += [{type:"local",tag:$dns_tag}]
    end |
    .outbounds += [{type:"direct",tag:$tag,domain_resolver:{server:$dns_tag,strategy:$strategy}} + {($field):$ip}]' \
    "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp" >/dev/null; then
    printf '%s' "$tag"
  else
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
}

_local_prefer6_tag_for_pair() {
  local ipv6=$1 ipv4=$2 digest
  digest=$(printf 'prefer_ipv6\0%s\0%s' "$ipv6" "$ipv4" | openssl dgst -sha256 -r | awk '{print $1}')
  printf 'local-prefer6-%s' "${digest:0:16}"
}

_build_prefer_ipv6_outbound_json() {
  local __var=$1 tag=$2 ipv6=$3 ipv4=$4 version strategy_fields json
  version=$(sing_box_version)
  [[ -n $version ]] || { warn "无法识别 sing-box 版本，不能创建 IPv6 fallback 出站。"; return 1; }

  # This is TCP Happy Eyeballs for domain destinations: IPv6 starts first and
  # IPv4 starts after fallback_delay when IPv6 is still pending. UDP has no
  # equivalent connection race and is not guaranteed to escape a black hole.
  # The repository already has a tagged local DNS resolver. Use the
  # domain_resolver path for every supported sing-box version: 1.13 rejects
  # legacy domain_strategy by default, and 1.14 removes that legacy field.
  version_ge "$version" 1.12.0 || {
    warn "IPv6 fallback 需要 sing-box >= 1.12.0。"
    return 1
  }
  strategy_fields=$(jq -nc '{domain_resolver:{server:"sbctl-local-dns",strategy:"prefer_ipv6"}}')
  json=$(jq -nc --arg tag "$tag" --arg ipv6 "$ipv6" --arg ipv4 "$ipv4" \
    --argjson strategy_fields "$strategy_fields" '
    {type:"direct",tag:$tag,inet6_bind_address:$ipv6,inet4_bind_address:$ipv4,
     fallback_delay:"300ms"} + $strategy_fields')
  printf -v "$__var" '%s' "$json"
}

_ensure_prefer_ipv6_outbound() {
  local ipv6=$1 ipv4=$2 tag outbound tmp dns_tag=sbctl-local-dns
  [[ $ipv6 == *:* ]] || { warn "IPv6 fallback 出站需要 IPv6 地址。"; return 1; }
  validate_ip_literal "$ipv6" || { warn "IPv6 地址无效。"; return 1; }
  validate_ipv4 "$ipv4" || { warn "IPv4 fallback 地址无效。"; return 1; }
  tag=$(_local_prefer6_tag_for_pair "$ipv6" "$ipv4")
  _build_prefer_ipv6_outbound_json outbound "$tag" "$ipv6" "$ipv4" || return 1

  if jq -e --arg tag "$tag" --arg ipv6 "$ipv6" --arg ipv4 "$ipv4" '
    any(.outbounds[]?; .tag==$tag and
      (.type!="direct" or .inet6_bind_address!=$ipv6 or .inet4_bind_address!=$ipv4))
  ' "$CONFIG_FILE" >/dev/null; then
    warn "检测到 IPv6 fallback 出站标签冲突：${tag}。"
    return 1
  fi

  if jq -e --arg tag "$tag" --arg dns_tag "$dns_tag" --argjson outbound "$outbound" '
    any(.outbounds[]?; .tag==$tag and .==$outbound) and
    (($outbound.domain_resolver.server // "") != $dns_tag or
      any(.dns.servers[]?; .tag==$dns_tag))
  ' "$CONFIG_FILE" >/dev/null; then
    printf '%s' "$tag"
    return 0
  fi

  tmp=$(temp_file)
  jq --arg tag "$tag" --arg dns_tag "$dns_tag" --argjson outbound "$outbound" '
    if (($outbound.domain_resolver.server // "") == $dns_tag) then
      .dns=(.dns // {}) |
      .dns.servers=(.dns.servers // []) |
      if any(.dns.servers[]?; .tag==$dns_tag) then .
      else .dns.servers += [{type:"local",tag:$dns_tag}]
      end
    else . end |
    if any(.outbounds[]?; .tag==$tag) then
      .outbounds |= map(if .tag==$tag then $outbound else . end)
    else
      .outbounds += [$outbound]
    end' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp" >/dev/null; then
    printf '%s' "$tag"
  else
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
}

_select_ipv4_fallback() {
  local __var=$1 label ipv4 iface choice item
  local -a ipv4s=()
  while IFS=$'\t' read -r label ipv4 iface; do
    [[ $label == *'(IPv4)' ]] || continue
    local duplicate=0
    if ((${#ipv4s[@]})); then
      for item in "${ipv4s[@]}"; do
        [[ $item == "$ipv4" ]] && { duplicate=1; break; }
      done
    fi
    ((duplicate)) || ipv4s+=("$ipv4")
  done < <(detect_local_ips 2>/dev/null)

  if ((${#ipv4s[@]} == 0)); then
    warn "主机没有可用 IPv4 fallback，将继续使用纯 IPv6 出站。"
    printf -v "$__var" '%s' ''
    return 0
  fi
  choose choice "IPv4 回退" "不回退" "${ipv4s[@]}" || return 1
  if [[ $choice == 1 ]]; then
    printf -v "$__var" '%s' ''
  else
    printf -v "$__var" '%s' "${ipv4s[$((choice-2))]}"
  fi
}

current_outbound_for_inbound() {
  local inbound=$1 selected
  selected=$(jq -r --arg inbound "$inbound" '
    [(.route.rules // [])[]? |
      select(.action=="route" and (.inbound // [])==[$inbound] and
        ((keys_unsorted | sort) == (["action","inbound","outbound"] | sort))) |
      .outbound][0] // empty' "$CONFIG_FILE")
  if [[ -n $selected ]]; then printf '%s' "$selected"; else jq -r '.route.final // "direct"' "$CONFIG_FILE"; fi
}

_sbctl_managed_domain_rule_filter() {
  cat <<'JQ'
def sbctl_managed_domain_rule:
  type == "object" and
  .action == "route" and
  (.inbound | type) == "array" and
  (.inbound | length) == 1 and
  (.inbound[0] | type) == "string" and
  (.outbound | type) == "string" and
  (.outbound != "") and
  (
    ((keys_unsorted | sort) == (["action", "domain", "inbound", "outbound"] | sort) and
      (.domain | type) == "array" and
      (.domain | length) == 1 and
      (.domain[0] | type) == "string") or
    ((keys_unsorted | sort) == (["action", "domain_suffix", "inbound", "outbound"] | sort) and
      (.domain_suffix | type) == "array" and
      (.domain_suffix | length) == 1 and
      (.domain_suffix[0] | type) == "string")
  );
JQ
}

_sbctl_canonical_default_rule_filter() {
  cat <<'JQ'
def sbctl_canonical_default_rule:
  type == "object" and
  .action == "route" and
  (.inbound | type) == "array" and
  (.inbound | length) == 1 and
  (.inbound[0] | type) == "string" and
  (.outbound | type) == "string" and
  (.outbound != "") and
  ((keys_unsorted | sort) == (["action", "inbound", "outbound"] | sort));
JQ
}

_sbctl_domain_rule_insert_filter() {
  cat <<'JQ'
def sbctl_inbound_domain_rule($inbound):
  sbctl_managed_domain_rule and .inbound==[$inbound];

def sbctl_inbound_default_rule($inbound):
  sbctl_canonical_default_rule and .inbound==[$inbound];

def sbctl_suffix_is_broader($domain):
  (.domain_suffix[0] | split(".") | length) as $rule_depth |
  (.domain_suffix[0] | length) as $rule_length |
  ($domain | split(".") | length) as $domain_depth |
  ($domain | length) as $domain_length |
  ($rule_depth < $domain_depth or
    ($rule_depth == $domain_depth and $rule_length < $domain_length));

def sbctl_domain_insert_index($rules; $inbound; $match; $domain):
  (if $match=="exact" then
     ([$rules | to_entries[] as $entry |
       select(($entry.value | sbctl_inbound_domain_rule($inbound)) and
         ($entry.value | has("domain_suffix"))) | $entry.key][0] // null)
   else
     ([$rules | to_entries[] as $entry |
       select(($entry.value | sbctl_inbound_domain_rule($inbound)) and
         ($entry.value | has("domain_suffix")) and
         ($entry.value | sbctl_suffix_is_broader($domain))) | $entry.key][0] // null)
   end) as $priority_index |
  if $priority_index != null then $priority_index
  else
    ([$rules | to_entries[] as $entry |
      select($entry.value | sbctl_inbound_default_rule($inbound)) | $entry.key][0] // null) as $default_index |
    if $default_index != null then $default_index
    else
      ([$rules | to_entries[] as $entry |
        select($entry.value | sbctl_inbound_domain_rule($inbound)) | $entry.key] | last) as $last_domain_index |
      if $last_domain_index == null then null else ($last_domain_index + 1) end
    end
  end;

def sbctl_insert_rule($rules; $index; $new_rule):
  if $index == null then $rules + [$new_rule]
  else
    $rules[:$index] + [$new_rule] + $rules[$index:]
  end;
JQ
}

_short_ipv6() {
  local ip=$1 first last
  [[ $ip == *:* ]] || { printf '%s' "$ip"; return; }
  first=${ip%%:*}
  last=${ip##*:}
  [[ -n $first ]] || first=:
  [[ -n $last ]] || last=:
  printf '%s:...:%s' "$first" "$last"
}

_outbound_display_name() {
  local tag=$1 record inet4 inet6 strategy
  [[ $tag == direct ]] && { printf 'direct'; return; }
  record=$(jq -r --arg tag "$tag" '
    [.outbounds[]? | select(.tag==$tag)][0] |
    if . == null then ""
    else [(.inet4_bind_address // ""), (.inet6_bind_address // ""),
      (.domain_resolver.strategy // .domain_strategy // "")] | @tsv
    end' "$CONFIG_FILE" 2>/dev/null || true)
  if [[ -z $record ]]; then
    printf '%s' "$tag"
    return
  fi
  IFS=$'\t' read -r inet4 inet6 strategy <<<"$record"
  if [[ -n $inet6 && -n $inet4 && $strategy == prefer_ipv6 ]]; then
    printf '%s → %s' "$(_short_ipv6 "$inet6")" "$inet4"
  elif [[ -n $inet4 ]]; then
    printf '%s' "$inet4"
  elif [[ -n $inet6 ]]; then
    _short_ipv6 "$inet6"
  else
    printf '%s' "$tag"
  fi
}

_outbound_endpoint_display() {
  local server=$1 port=$2
  if [[ $server == *:* && $server != \[*\] ]]; then
    printf '[%s]:%s' "$(_short_ipv6 "$server")" "$port"
  else
    printf '%s:%s' "$(uri_host "$server")" "$port"
  fi
}

_normalize_domain_input() {
  local __var=$1 candidate
  candidate=$(printf '%s' "${2-}" | tr '[:upper:]' '[:lower:]')
  if [[ $candidate == \*.* ]]; then
    warn "请输入 ${candidate#\*.}，并选择“域名及所有子域名”。"
    return 1
  fi
  validate_domain "$candidate" || { warn "域名格式无效，请输入类似 openai.com 的域名。"; return 1; }
  printf -v "$__var" '%s' "$candidate"
}

_normalize_domain_list() {
  local raw=$1 item normalized
  local -a items=()
  [[ $raw != ,* && $raw != *, && $raw != *,,* ]] || {
    warn "域名列表中不能有空项，请使用英文逗号分隔域名。"
    return 1
  }
  IFS=',' read -r -a items <<<"$raw"
  ((${#items[@]})) || { warn "至少请输入一个域名。"; return 1; }
  for item in "${items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n $item ]] || { warn "域名列表中不能有空项，请使用英文逗号分隔域名。"; return 1; }
    _normalize_domain_input normalized "$item" || return 1
    printf '%s\n' "$normalized"
  done
}

_meta_template_add() {
  local current=$1 candidate=$2 name=$3
  jq --arg name "$name" '
    .domainTemplates=(.domainTemplates // {templates:[],bindings:[]}) |
    if any(.domainTemplates.templates[]?; .name==$name) then
      error("template already exists")
    else
      .domainTemplates.templates += [{name:$name,exact:[],suffix:[]}]
    end
  ' "$current" >"$candidate"
}

_meta_template_domains_add() {
  local current=$1 candidate=$2 name=$3 match=$4 domains_json=$5
  jq --arg name "$name" --arg match "$match" --argjson domains "$domains_json" '
    if ($match!="exact" and $match!="suffix") then error("invalid match")
    elif any(.domainTemplates.templates[]?; .name==$name) then
      .domainTemplates.templates |= map(
        if .name==$name then .[$match]=(((.[$match] // []) + $domains) | unique) else . end)
    else error("template not found") end
  ' "$current" >"$candidate"
}

_meta_template_domains_delete() {
  local current=$1 candidate=$2 name=$3 match=$4 domains_json=$5
  jq --arg name "$name" --arg match "$match" --argjson domains "$domains_json" '
    if ($match!="exact" and $match!="suffix") then error("invalid match")
    elif any(.domainTemplates.templates[]?; .name==$name) then
      .domainTemplates.templates |= map(
        if .name==$name then
          .[$match]=[.[$match][]? as $domain | select(($domains | index($domain)) == null) | $domain]
        else . end)
    else error("template not found") end
  ' "$current" >"$candidate"
}

_meta_template_bind() {
  local current=$1 candidate=$2 inbound=$3 name=$4 outbound=$5
  jq --arg inbound "$inbound" --arg name "$name" --arg outbound "$outbound" '
    .domainTemplates=(.domainTemplates // {templates:[],bindings:[]}) |
    if any(.domainTemplates.templates[]?; .name==$name) then
      .domainTemplates.bindings=(
        [.domainTemplates.bindings[]? | select(.inbound!=$inbound or .template!=$name)] +
        [{inbound:$inbound,template:$name,outbound:$outbound}])
    else error("template not found") end
  ' "$current" >"$candidate"
}

_meta_template_unbind() {
  local current=$1 candidate=$2 inbound=$3 name=$4
  jq --arg inbound "$inbound" --arg name "$name" '
    .domainTemplates=(.domainTemplates // {templates:[],bindings:[]}) |
    .domainTemplates.bindings=[.domainTemplates.bindings[]? |
      select(.inbound!=$inbound or .template!=$name)]
  ' "$current" >"$candidate"
}

_meta_template_set_outbound() {
  local current=$1 candidate=$2 inbound=$3 name=$4 outbound=$5
  jq --arg inbound "$inbound" --arg name "$name" --arg outbound "$outbound" '
    if any(.domainTemplates.bindings[]?; .inbound==$inbound and .template==$name) then
      .domainTemplates.bindings |= map(
        if .inbound==$inbound and .template==$name then .outbound=$outbound else . end)
    else error("binding not found") end
  ' "$current" >"$candidate"
}

list_domain_templates() {
  init_meta
  jq -r '.domainTemplates.templates[]? |
    [.name,((.exact // [])|length),((.suffix // [])|length)] | @tsv' "$META_FILE"
}

domain_template_exists() {
  init_meta
  jq -e --arg name "$1" 'any(.domainTemplates.templates[]?; .name==$name)' "$META_FILE" >/dev/null
}

list_inbound_template_bindings() {
  init_meta
  jq -r --arg inbound "$1" '.domainTemplates.bindings[]? |
    select(.inbound==$inbound) | [.template,.outbound] | @tsv' "$META_FILE"
}

# Later bindings win when multiple templates contain the same domain.
_inbound_desired_template_entries() {
  local __var=$1 metadata=$2 inbound=$3 result
  result=$(jq -c --arg inbound "$inbound" '
    .domainTemplates as $templates |
    [$templates.bindings[]? | select(.inbound==$inbound)] as $bindings |
    reduce (
      $bindings[] as $binding |
      ($templates.templates[]? | select(.name==$binding.template)) as $template |
      (($template.exact[]? | {match:"exact",domain:.,key:("exact:"+.)}),
       ($template.suffix[]? | {match:"suffix",domain:.,key:("suffix:"+.)})) |
      {key:.key,match:.match,domain:.domain,template:$binding.template,outbound:$binding.outbound}
    ) as $entry ({}; .[$entry.key]=$entry) |
    [.[]]
  ' "$metadata") || return 1
  printf -v "$__var" '%s' "$result"
}

_sbctl_reconcile_template_filter() {
  _sbctl_managed_domain_rule_filter
  cat <<'JQ'
def sbctl_rule_key:
  if has("domain_suffix") then "suffix:"+.domain_suffix[0]
  elif has("domain") then "exact:"+.domain[0]
  else "" end;
($desired | map({key:.key,value:.}) | from_entries) as $desired_map |
.route=(.route // {}) |
.route.rules=[(.route.rules // [])[]? |
  (sbctl_rule_key) as $key |
  if (sbctl_managed_domain_rule and .inbound==[$inbound] and (($owned | index($key)) != null)) then
    if $desired_map[$key] != null then
      .outbound=$desired_map[$key].outbound
    else empty end
  else . end]
JQ
}

_sbctl_missing_template_filter() {
  _sbctl_managed_domain_rule_filter
  cat <<'JQ'
def sbctl_rule_key:
  if has("domain_suffix") then "suffix:"+.domain_suffix[0]
  elif has("domain") then "exact:"+.domain[0]
  else "" end;
([.route.rules[]? | select(sbctl_managed_domain_rule and .inbound==[$inbound]) | sbctl_rule_key]) as $present |
[$desired[] | select(.key as $key | ($present | index($key)) == null)]
JQ
}

_sbctl_insert_template_filter() {
  _sbctl_managed_domain_rule_filter
  _sbctl_canonical_default_rule_filter
  _sbctl_domain_rule_insert_filter
  cat <<'JQ'
def insert_template_rule($rules; $entry):
  ($rules | sbctl_domain_insert_index($rules; $inbound; $entry.match; $entry.domain)) as $index |
  sbctl_insert_rule($rules; $index;
    ({inbound:[$inbound]} +
     (if $entry.match=="suffix" then {domain_suffix:[$entry.domain]} else {domain:[$entry.domain]} end) +
     {action:"route",outbound:$entry.outbound}));
.route=(.route // {}) |
(.route.rules // []) as $rules |
.route.rules=(reduce $additions[] as $entry ($rules; insert_template_rule(.; $entry)))
JQ
}

_rebuild_inbound_template_config() {
  local __var=$1 base=$2 inbound=$3 metadata=$4 desired owned reconciled missing present new_owned metadata_next candidate
  _inbound_desired_template_entries desired "$metadata" "$inbound" || return 1
  owned=$(jq -c --arg inbound "$inbound" '[.domainTemplates.managed[]? |
    select(.inbound==$inbound) | .match+":"+.domain]' "$metadata") || return 1
  reconciled=$(temp_file)
  jq --arg inbound "$inbound" --argjson desired "$desired" --argjson owned "$owned" \
    "$(_sbctl_reconcile_template_filter)" "$base" >"$reconciled" || { rm -f "$reconciled"; return 1; }

  missing=$(jq -c --arg inbound "$inbound" --argjson desired "$desired" \
    "$(_sbctl_missing_template_filter)" "$reconciled") || { rm -f "$reconciled"; return 1; }

  present=$(jq -c --arg inbound "$inbound" "$(_sbctl_managed_domain_rule_filter)
    def rule_key: if has(\"domain_suffix\") then \"suffix:\"+.domain_suffix[0] else \"exact:\"+.domain[0] end;
    [.route.rules[]? | select(sbctl_managed_domain_rule and .inbound==[\$inbound]) | rule_key]
  " "$reconciled") || { rm -f "$reconciled"; return 1; }
  new_owned=$(jq -nc --arg inbound "$inbound" --argjson desired "$desired" --argjson owned "$owned" --argjson present "$present" '
    [$desired[] | . as $entry |
      select(($owned | index($entry.key)) != null or ($present | index($entry.key)) == null) |
      {inbound:$inbound,match:$entry.match,domain:$entry.domain}]') || { rm -f "$reconciled"; return 1; }
  metadata_next=$(temp_file)
  jq --arg inbound "$inbound" --argjson managed "$new_owned" '
    .domainTemplates.managed=([.domainTemplates.managed[]? | select(.inbound!=$inbound)] + $managed)
  ' "$metadata" >"$metadata_next" || { rm -f "$reconciled" "$metadata_next"; return 1; }
  mv -f "$metadata_next" "$metadata"

  if [[ $missing == '[]' ]]; then
    printf -v "$__var" '%s' "$reconciled"
    return 0
  fi

  candidate=$(temp_file)
  jq --arg inbound "$inbound" --argjson additions "$missing" \
    "$(_sbctl_insert_template_filter)" "$reconciled" >"$candidate" || { rm -f "$reconciled" "$candidate"; return 1; }
  rm -f "$reconciled"
  printf -v "$__var" '%s' "$candidate"
}

_rebuild_template_bound_inbounds_config() {
  local __var=$1 metadata=$2 name=$3 current next inbound
  current=$(temp_file)
  cp "$CONFIG_FILE" "$current"
  while IFS= read -r inbound; do
    [[ -n $inbound ]] || continue
    if ! _rebuild_inbound_template_config next "$current" "$inbound" "$metadata"; then
      rm -f "$current"
      return 1
    fi
    rm -f "$current"
    current=$next
  done < <(jq -r --arg name "$name" '.domainTemplates.bindings[]? |
    select(.template==$name) | .inbound' "$metadata")
  printf -v "$__var" '%s' "$current"
}

_commit_template_change() {
  local config_candidate=$1 metadata_candidate=$2 message=$3 rc=0
  if cmp -s "$CONFIG_FILE" "$config_candidate"; then
    commit_metadata_candidate "$metadata_candidate" || rc=$?
  else
    apply_candidate_with_meta "$config_candidate" "$metadata_candidate" >/dev/null || rc=$?
  fi
  rm -f "$config_candidate" "$metadata_candidate"
  ((rc == 0)) || return "$rc"
  info "$message"
}

create_domain_template() {
  ensure_dependencies outbound-template-create; ensure_config; init_meta
  local name
  prompt_value name "模板名称" || return 1
  validate_tag "$name" || { warn "模板名称只能包含字母、数字、点、下划线和横线。"; return 1; }
  if domain_template_exists "$name"; then warn "模板已存在：${name}"; return 1; fi
  commit_metadata_mutation _meta_template_add "$name" || return 1
  info "模板 ${name} 已创建。"
}

apply_domain_template() {
  ensure_dependencies outbound-template-apply; require_supported_core; ensure_config; init_meta
  local inbound=$1 name=$2 outbound=$3 metadata_candidate config_candidate
  inbound_exists "$inbound" || die "找不到入站：$inbound"
  domain_template_exists "$name" || die "找不到模板：$name"
  [[ $outbound == direct ]] || outbound_exists "$outbound" || die "找不到出站：$outbound"
  metadata_candidate=$(temp_file)
  _meta_template_bind "$META_FILE" "$metadata_candidate" "$inbound" "$name" "$outbound" || { rm -f "$metadata_candidate"; return 1; }
  _rebuild_inbound_template_config config_candidate "$CONFIG_FILE" "$inbound" "$metadata_candidate" || { rm -f "$metadata_candidate"; return 1; }
  _commit_template_change "$config_candidate" "$metadata_candidate" "模板 ${name} 已应用到入站 ${inbound}（出站：${outbound}）。"
}

add_domain_template_domains() {
  ensure_dependencies outbound-template-edit; require_supported_core; ensure_config; init_meta
  local name=$1 match=$2 raw=$3 normalized domains_json metadata_candidate config_candidate
  normalized=$(_normalize_domain_list "$raw") || return 1
  domains_json=$(printf '%s\n' "$normalized" | jq -Rsc 'split("\n") | map(select(length>0)) | unique')
  metadata_candidate=$(temp_file)
  _meta_template_domains_add "$META_FILE" "$metadata_candidate" "$name" "$match" "$domains_json" || { rm -f "$metadata_candidate"; return 1; }
  _rebuild_template_bound_inbounds_config config_candidate "$metadata_candidate" "$name" || { rm -f "$metadata_candidate"; return 1; }
  _commit_template_change "$config_candidate" "$metadata_candidate" "模板 ${name} 已更新，已同步到已应用的入站。"
}

delete_domain_template_domains() {
  ensure_dependencies outbound-template-edit; require_supported_core; ensure_config; init_meta
  local name=$1 match=$2 raw=$3 normalized domains_json metadata_candidate config_candidate
  normalized=$(_normalize_domain_list "$raw") || return 1
  domains_json=$(printf '%s\n' "$normalized" | jq -Rsc 'split("\n") | map(select(length>0)) | unique')
  metadata_candidate=$(temp_file)
  _meta_template_domains_delete "$META_FILE" "$metadata_candidate" "$name" "$match" "$domains_json" || { rm -f "$metadata_candidate"; return 1; }
  _rebuild_template_bound_inbounds_config config_candidate "$metadata_candidate" "$name" || { rm -f "$metadata_candidate"; return 1; }
  _commit_template_change "$config_candidate" "$metadata_candidate" "模板 ${name} 已更新，已同步删除已应用入站中的规则。"
}

remove_domain_template() {
  ensure_dependencies outbound-template-remove; require_supported_core; ensure_config; init_meta
  local inbound=$1 name=$2 metadata_candidate config_candidate
  metadata_candidate=$(temp_file)
  _meta_template_unbind "$META_FILE" "$metadata_candidate" "$inbound" "$name" || { rm -f "$metadata_candidate"; return 1; }
  _rebuild_inbound_template_config config_candidate "$CONFIG_FILE" "$inbound" "$metadata_candidate" || { rm -f "$metadata_candidate"; return 1; }
  _commit_template_change "$config_candidate" "$metadata_candidate" "已从入站 ${inbound} 移除模板 ${name}。"
}

update_domain_template_outbound() {
  ensure_dependencies outbound-template-set-outbound; require_supported_core; ensure_config; init_meta
  local inbound=$1 name=$2 outbound=$3 metadata_candidate config_candidate
  inbound_exists "$inbound" || die "找不到入站：$inbound"
  domain_template_exists "$name" || die "找不到模板：$name"
  [[ $outbound == direct ]] || outbound_exists "$outbound" || die "找不到出站：$outbound"
  metadata_candidate=$(temp_file)
  _meta_template_set_outbound "$META_FILE" "$metadata_candidate" "$inbound" "$name" "$outbound" || { rm -f "$metadata_candidate"; return 1; }
  _rebuild_inbound_template_config config_candidate "$CONFIG_FILE" "$inbound" "$metadata_candidate" || { rm -f "$metadata_candidate"; return 1; }
  _commit_template_change "$config_candidate" "$metadata_candidate" "模板 ${name} 的出站已更新为 ${outbound}（入站：${inbound}）。"
}

# Pure display — only sbctl's strict canonical domain rules are shown.
list_domain_rules() {
  ensure_dependencies outbound-rule-list; ensure_config
  local inbound=${1-} context=${2-} row group_inbound="" number=0 match domain outbound group_start display match_label hide_templates=0 owned
  [[ -z $inbound ]] || inbound_exists "$inbound" || die "找不到入站：$inbound"
  [[ $context == --menu ]] && hide_templates=1
  owned=$(jq -c '.domainTemplates.managed // []' "$META_FILE")
  row=$(jq -r --arg inbound "$inbound" --arg hideTemplates "$hide_templates" --argjson owned "$owned" "$(_sbctl_managed_domain_rule_filter)
    def template_owned:
      (. as \$rule | any(\$owned[];
        .inbound==\$rule.inbound[0] and
        ((.match==\"suffix\" and \$rule.domain_suffix==[.domain]) or
         (.match==\"exact\" and \$rule.domain==[.domain]))));
    ([.route.rules[]? |
      select(sbctl_managed_domain_rule and (\$hideTemplates!=\"1\" or (template_owned|not))) |
      .inbound[0] as \$rule_inbound |
      (if has(\"domain_suffix\") then \"suffix\" else \"exact\" end) as \$match |
      (if \$match==\"suffix\" then .domain_suffix[0] else .domain[0] end) as \$domain |
      [\$rule_inbound,\$match,\$domain,.outbound]] ) as \$rows |
    [.inbounds[].tag] as \$inbound_order |
    \$inbound_order[] as \$group |
    select(\$inbound==\"\" or \$group==\$inbound) |
    (\$rows |
      map(select(.[0]==\$group)) |
      sort_by([(if .[1]==\"suffix\" then 0 else 1 end), .[3]]) |
      group_by([.[1], .[3]])[] |
      sort_by([(.[2] | ascii_downcase), .[2]]) |
      to_entries[] |
      .value + [(if .key==0 then \"first\" else \"\" end)]
    ) | @tsv" "$CONFIG_FILE")
  heading "域名分流规则"
  [[ -n $row ]] || { info "还没有直接域名规则。"; return 0; }
  while IFS=$'\t' read -r inbound match domain outbound group_start; do
    [[ -n $inbound ]] || continue
    if [[ $inbound != "$group_inbound" ]]; then
      group_inbound=$inbound
      number=0
      [[ $context == --menu ]] || printf '\n%s入站：%s%s\n' "$C_BOLD$C_CYAN" "$group_inbound" "$C_RESET"
    fi
    if [[ $group_start == first ]]; then
      [[ $match == suffix ]] && match_label="子域名" || match_label="精确"
      display=$(_outbound_display_name "$outbound")
      printf '\n%s%s%s → %s%s%s\n' \
        "$C_BOLD$C_CYAN" "$match_label" "$C_RESET" \
        "$C_BOLD$C_GREEN" "$display" "$C_RESET"
    fi
    ((number+=1))
    print_table_cell "$number" 4; printf '  '
    print_table_cell "$domain" 24
    printf '\n'
  done <<<"$row"
}

# Pure display — does NOT call ensure_config. Callers must validate config.
list_outbound_overview() {
  [[ -f $CONFIG_FILE ]] || { info "还没有配置。"; return 0; }
  local inbound outbound type server port user number=0
  heading "入站与出站规则"
  if ! jq -e '.inbounds|length>0' "$CONFIG_FILE" >/dev/null; then
    info "还没有入站。"
  else
    print_table_cell_clipped "入站" 26; printf '| 出站\n'
    while IFS= read -r inbound; do
      outbound=$(current_outbound_for_inbound "$inbound")
      local display; display=$(_outbound_display_name "$outbound")
      print_table_cell_clipped "$inbound" 26; printf '| %s\n' "$display"
    done < <(jq -r '.inbounds[].tag' "$CONFIG_FILE")
  fi

  heading "SOCKS5 / HTTP 出站"
  if ! jq -e '.outbounds[]?|select(.type=="socks" or .type=="http")' "$CONFIG_FILE" >/dev/null; then
    info "还没有代理出站。"
    return 0
  fi
  print_table_cell "序号" 4; printf '| '
  print_table_cell_clipped "标签" 16; printf '| '
  print_table_cell "协议" 7; printf '| '
  print_table_cell_clipped "地址" 22; printf '| 用户\n'
  while IFS=$'\t' read -r outbound type server port user; do
    ((number+=1))
    print_table_cell "$number" 4; printf '| '
    print_table_cell_clipped "$outbound" 16; printf '| '
    print_table_cell "$type" 7; printf '| '
    print_table_cell_clipped "$(_outbound_endpoint_display "$server" "$port")" 22; printf '| %s\n' "${user:-无}"
  done < <(jq -r '.outbounds[]?|select(.type=="socks" or .type=="http")|[.tag,.type,.server,(.server_port|tostring),(.username//"")]|@tsv' "$CONFIG_FILE")
}

show_outbound_details() {
  ensure_config
  local tag=${1-} answer item
  local -a tags=()
  while IFS= read -r item; do
    [[ -n $item ]] && tags+=("$item")
  done < <(jq -r '.outbounds[]?|select(.type=="socks" or .type=="http")|.tag' "$CONFIG_FILE")
  ((${#tags[@]})) || { info "还没有手动添加的代理出站。"; return 0; }

  if [[ -z $tag ]]; then
    if ((${#tags[@]} == 1)); then
      tag=${tags[0]}
    else
      choose answer "选择要查看的代理出站" "${tags[@]}" || return 0
      tag=${tags[$((answer-1))]}
    fi
  fi
  [[ $tag != direct ]] || { warn "这里只显示手动添加的 SOCKS5/HTTP 出站。"; return 0; }
  jq -e --arg tag "$tag" '.outbounds[]?|select((.type=="socks" or .type=="http") and .tag==$tag)' "$CONFIG_FILE" >/dev/null \
    || die "找不到手动添加的代理出站：$tag"

  heading "出站详情"
  printf '出站：%s\n\n' "$tag"
  jq --arg tag "$tag" '.outbounds[]|select((.type=="socks" or .type=="http") and .tag==$tag)' "$CONFIG_FILE"
}

prompt_outbound_tag() {
  local __var=$1 default=$2 candidate
  while true; do
    prompt_value candidate "出站标签" "$default" || return 1
    validate_tag "$candidate" || { warn "标签只能包含字母、数字、点、下划线和横线。"; continue; }
    if outbound_exists "$candidate" || inbound_exists "$candidate"; then warn "标签已存在。"; continue; fi
    printf -v "$__var" '%s' "$candidate"
    return 0
  done
}

add_outbound() {
  ensure_dependencies outbound-add; require_supported_core; ensure_config
  local choice type tag server port auth username="" password="" outbound tmp
  choose choice "选择出站协议" "SOCKS5" "HTTP"
  [[ $choice == 1 ]] && type=socks || type=http
  prompt_outbound_tag tag "${type}-out-$(random_hex 2)"
  prompt_value server "代理服务器地址"
  prompt_value port "代理服务器端口"
  validate_port "$port" || die "端口必须为 1-65535。"
  choose auth "认证方式" "无认证" "用户名密码"
  if [[ $auth == 2 ]]; then
    prompt_value username "用户名"
    prompt_secret password "密码"
  fi
  if [[ $type == socks ]]; then
    outbound=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg user "$username" --arg pass "$password" '
      {type:"socks",tag:$tag,server:$server,server_port:$port,version:"5"} |
      if $user!="" then .username=$user|.password=$pass else . end')
  else
    outbound=$(jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg user "$username" --arg pass "$password" '
      {type:"http",tag:$tag,server:$server,server_port:$port} |
      if $user!="" then .username=$user|.password=$pass else . end')
  fi
  tmp=$(temp_file)
  jq --argjson outbound "$outbound" '.outbounds += [$outbound]' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then info "出站 ${tag} 已添加。"; fi
  rm -f "$tmp"
}

select_outbound() {
  local __var=$1 include_direct=${2:-1} item answer selected
  local tags=() local_ips=() local_ip_tags=() local_raw_ips=()
  ((include_direct == 0)) || tags+=(direct)
  while IFS= read -r item; do [[ -n $item ]] && tags+=("$item"); done < <(
    jq -r '.outbounds[]?|select(.type=="socks" or .type=="http")|.tag' "$CONFIG_FILE"
  )
  # 检测本地 IP
  while IFS=$'\t' read -r label ip iface; do
    local tag; tag=$(_local_tag_for_ip "$ip")
    local_ip_tags+=("$tag")
    local found=0
    for t in "${tags[@]}"; do [[ $t == "$tag" ]] && { found=1; break; }; done
    if ((!found)); then tags+=("$tag"); fi
    local_ips+=("$label")
    local_raw_ips+=("$ip")
  done < <(ensure_config 2>/dev/null || true; detect_local_ips 2>/dev/null)
  ((${#tags[@]})) || { warn "没有可选出站。"; return 1; }
  # 构建显示标签
  local display_labels=()
  for t in "${tags[@]}"; do
    if [[ $t == direct ]]; then
      display_labels+=("direct")
    elif [[ $t =~ ^local- ]]; then
      local dlabel="" found=0 i
      for ((i=0; i<${#local_ip_tags[@]}; i++)); do
        [[ ${local_ip_tags[$i]} == "$t" ]] && { dlabel="${local_ips[$i]}"; found=1; break; }
      done
      if ((found)); then display_labels+=("${dlabel%% *}"); else display_labels+=("$t"); fi
    else
      display_labels+=("$t")
    fi
  done
  choose answer "选择出站" "${display_labels[@]}"
  selected=${tags[$((answer-1))]}
  if [[ $selected =~ ^local- ]]; then
    local ip=""
    ip=$(jq -r --arg tag "$selected" '.outbounds[]?|select(.tag==$tag)|(.inet4_bind_address // .inet6_bind_address // empty)' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ -z $ip ]]; then
      for ((i=0; i<${#local_ip_tags[@]}; i++)); do
        [[ ${local_ip_tags[$i]} == "$selected" ]] && { ip="${local_raw_ips[$i]}"; break; }
      done
    fi
    [[ -n $ip ]] || { error "无法解析本地 IP。"; return 1; }
    if [[ $ip == *:* ]]; then
      local fallback_ipv4=""
      _select_ipv4_fallback fallback_ipv4 || return 1
      if [[ -n $fallback_ipv4 ]]; then
        selected=$(_ensure_prefer_ipv6_outbound "$ip" "$fallback_ipv4") || {
          error "无法创建 IPv6 fallback 出站。"
          return 1
        }
      else
        selected=$(_ensure_local_outbound "$ip") || { error "无法创建本地出口。"; return 1; }
      fi
    else
      selected=$(_ensure_local_outbound "$ip") || { error "无法创建本地出口。"; return 1; }
    fi
  fi
  printf -v "$__var" '%s' "$selected"
}

assign_outbound() {
  ensure_dependencies outbound-assign; require_supported_core; ensure_config
  local inbound=${1-} outbound=${2-} tmp
  [[ -n $inbound ]] || select_inbound inbound || return 0
  inbound_exists "$inbound" || die "找不到入站：$inbound"
  [[ -n $outbound ]] || select_outbound outbound 1 || return 0
  [[ $outbound == direct ]] || outbound_exists "$outbound" || die "找不到出站：$outbound"

  tmp=$(temp_file)
  jq --arg inbound "$inbound" --arg outbound "$outbound" '
    .route = (.route // {}) |
    .route.rules = ((.route.rules // []) | map(
      select(.action!="route" or (.inbound // [])!=[$inbound] or
        ((keys_unsorted | sort) != (["action","inbound","outbound"] | sort))))) |
    if $outbound=="direct" then .
    else .route.rules += [{inbound:[$inbound],action:"route",outbound:$outbound}] end' \
    "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then info "入站 ${inbound} 已设置为出站 ${outbound}。"; fi
  rm -f "$tmp"
}

add_domain_rule() {
  ensure_dependencies outbound-rule-add; require_supported_core; ensure_config
  local inbound=${1-} match=${2-} domain=${3-} outbound=${4-} prompt_details=${5-} choice tmp
  local normalized_domains normalized_domains_json existing_domains existing_domains_json domain_summary domain_count
  local cli=0
  if [[ $prompt_details == --prompt ]]; then
    [[ -n $inbound && -z $match && -z $domain && -z $outbound ]] || die "内部调用参数无效。"
    inbound_exists "$inbound" || die "找不到入站：$inbound"
  elif [[ -n $inbound || -n $match || -n $domain || -n $outbound ]]; then
    cli=1
    [[ -n $inbound && -n $match && -n $domain && -n $outbound ]] || \
      die "用法：sbctl outbound rule add [入站] [suffix|exact] [域名] [出站]"
    inbound_exists "$inbound" || die "找不到入站：$inbound"
    case $match in
      suffix|exact) ;;
      *) die "匹配方式只能是 suffix 或 exact。";;
    esac
    [[ $outbound == direct ]] || outbound_exists "$outbound" || die "找不到出站：$outbound"
  else
    select_inbound inbound || return 0
  fi
  if ((cli == 0)); then
    choose choice "匹配方式" "域名及所有子域名" "仅精确域名" || return 0
    [[ $choice == 1 ]] && match=suffix || match=exact
    while true; do
      prompt_value domain "域名（多个用英文逗号分隔）" || return 0
      if normalized_domains=$(_normalize_domain_list "$domain"); then break; fi
    done
    select_outbound outbound 1 || return 0
  fi

  if ((cli)); then
    normalized_domains=$(_normalize_domain_list "$domain") || die "域名列表无效。"
  fi
  normalized_domains_json=$(printf '%s\n' "$normalized_domains" | jq -Rsc '
    split("\n") | map(select(length > 0)) |
    reduce .[] as $domain ([]; if index($domain) then . else . + [$domain] end)')
  existing_domains_json=$(jq -c --arg inbound "$inbound" --arg match "$match" --argjson domains "$normalized_domains_json" "$(_sbctl_managed_domain_rule_filter)
    def sbctl_rule_domain(\$rule):
      (\$rule | if \$match==\"suffix\" then .domain_suffix[0] else .domain[0] end);
    [.route.rules[]? |
      select(sbctl_managed_domain_rule and .inbound==[\$inbound]) |
      (.) as \$rule |
      select(any(\$domains[]; . == sbctl_rule_domain(\$rule))) |
      sbctl_rule_domain(\$rule)] | unique" "$CONFIG_FILE")
  existing_domains=$(jq -r 'join(",")' <<<"$existing_domains_json")
  if [[ -n $existing_domains ]]; then
    warn "已跳过已有域名规则：${inbound} ${match} ${existing_domains}。"
  fi
  normalized_domains_json=$(jq -c --argjson existing "$existing_domains_json" '
    [.[] as $domain | select(($existing | index($domain)) == null) | $domain]' \
    <<<"$normalized_domains_json")
  domain_count=$(jq -r 'length' <<<"$normalized_domains_json")
  if ((domain_count == 0)); then
    info "没有需要添加的新域名规则。"
    return 0
  fi
  domain_summary=$(jq -r 'join(",")' <<<"$normalized_domains_json")
  tmp=$(temp_file)
  jq --arg inbound "$inbound" --arg match "$match" --arg outbound "$outbound" \
    --argjson domains "$normalized_domains_json" "$(_sbctl_managed_domain_rule_filter)
    $(_sbctl_canonical_default_rule_filter)
    $(_sbctl_domain_rule_insert_filter)
    def sbctl_insert_domain_rule(\$rules; \$domain):
      (\$rules | sbctl_domain_insert_index(\$rules; \$inbound; \$match; \$domain)) as \$index |
      sbctl_insert_rule(\$rules; \$index;
        ({inbound:[\$inbound]} +
         (if \$match==\"suffix\" then {domain_suffix:[\$domain]} else {domain:[\$domain]} end) +
         {action:\"route\",outbound:\$outbound}));
    .route=(.route // {}) |
    (.route.rules // []) as \$rules |
    .route.rules=(reduce \$domains[] as \$domain (\$rules; sbctl_insert_domain_rule(.; \$domain)))" \
    "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then
    if ((domain_count == 1)); then
      info "已添加域名规则：${inbound} ${match} ${domain_summary} -> ${outbound}。"
    else
      info "已批量添加 ${domain_count} 条域名规则：${inbound} ${match} ${domain_summary} -> ${outbound}。"
    fi
  fi
  rm -f "$tmp"
}

delete_domain_rule() {
  ensure_dependencies outbound-rule-delete; require_supported_core; ensure_config
  local inbound=${1-} match=${2-} domain=${3-} scope=${4:---direct-only}
  local row choice selected_inbound tmp selection token idx inbound_row inbound_tag inbound_count template_owned owned
  local selected_json='[]' match_label display selected_match selected_domain selected_outbound
  local -a inbound_tags=() inbound_labels=() rule_matches=() rule_domains=() rule_outbounds=() requested=()
  init_meta
  owned=$(jq -c '.domainTemplates.managed // []' "$META_FILE")

  if [[ -n $match || -n $domain ]]; then
    [[ -n $inbound && -n $match && -n $domain ]] || die "用法：sbctl outbound rule delete [入站] [suffix|exact] [域名]"
    case $match in suffix|exact) ;; *) die "匹配方式只能是 suffix 或 exact。";; esac
    _normalize_domain_input domain "$domain" || die "域名格式无效。"
    inbound_exists "$inbound" || die "找不到入站：$inbound"
    selected_inbound=$inbound
    template_owned=$(jq -r --arg inbound "$inbound" --arg match "$match" --arg domain "$domain" '
      [.domainTemplates.managed[]? | select(.inbound==$inbound and .match==$match and .domain==$domain)] | length' "$META_FILE")
    ((template_owned == 0)) || die "该域名规则由模板管理，请在“管理模板”中调整模板或移除模板。"
    row=$(jq -r --arg inbound "$inbound" --arg match "$match" --arg domain "$domain" "$(_sbctl_managed_domain_rule_filter)
      [.route.rules[]? | select(sbctl_managed_domain_rule and .inbound==[\$inbound]) |
       select((if \$match==\"suffix\" then .domain_suffix else .domain end)==[\$domain])] | length" "$CONFIG_FILE")
    if ((row == 0)); then
      die "找不到域名规则：${inbound} ${match} ${domain}"
    fi
    ((row == 1)) || die "域名规则存在重复项，请先使用交互菜单处理。"
    selected_json=$(jq -nc --arg match "$match" --arg domain "$domain" '[{match:$match,domain:$domain}]')
  else
    [[ -z $inbound ]] || inbound_exists "$inbound" || die "找不到入站：$inbound"
    if [[ -z $inbound ]]; then
      inbound_row=$(jq -r --arg scope "$scope" --argjson owned "$owned" "$(_sbctl_managed_domain_rule_filter)
        def template_owned:
          (. as \$rule | any(\$owned[]; .inbound==\$rule.inbound[0] and
            ((.match==\"suffix\" and \$rule.domain_suffix==[.domain]) or
             (.match==\"exact\" and \$rule.domain==[.domain]))));
        ([.route.rules[]? | select(sbctl_managed_domain_rule and
          (\$scope!=\"--direct-only\" or (template_owned|not)))] ) as \$managed |
        [.inbounds[].tag] as \$inbound_order |
        \$inbound_order[] as \$tag |
        [\$managed[] | select(.inbound==[\$tag])] | length as \$count |
        select(\$count > 0) | [\$tag,\$count] | @tsv" "$CONFIG_FILE")
      while IFS=$'\t' read -r inbound_tag inbound_count; do
        [[ -n $inbound_tag ]] || continue
        inbound_tags+=("$inbound_tag"); inbound_labels+=("${inbound_tag}（${inbound_count} 条）")
      done <<<"$inbound_row"
      ((${#inbound_tags[@]})) || { warn "没有可删除的域名分流规则。"; return 0; }
      if ((${#inbound_tags[@]} == 1)); then selected_inbound=${inbound_tags[0]}
      else choose choice "选择入站" "${inbound_labels[@]}" || return 0; selected_inbound=${inbound_tags[$((choice-1))]}; fi
    else
      selected_inbound=$inbound
    fi

    row=$(jq -r --arg inbound "$selected_inbound" --arg scope "$scope" --argjson owned "$owned" "$(_sbctl_managed_domain_rule_filter)
      def template_owned:
        (. as \$rule | any(\$owned[]; .inbound==\$rule.inbound[0] and
          ((.match==\"suffix\" and \$rule.domain_suffix==[.domain]) or
           (.match==\"exact\" and \$rule.domain==[.domain]))));
      [.route.rules[]? |
        select(sbctl_managed_domain_rule and .inbound==[\$inbound] and
          (\$scope!=\"--direct-only\" or (template_owned|not))) |
        (if has(\"domain_suffix\") then \"suffix\" else \"exact\" end) as \$match |
        (if \$match==\"suffix\" then .domain_suffix[0] else .domain[0] end) as \$domain |
        [\$match,\$domain,.outbound]] as \$rules |
      (\$rules | sort_by([(if .[0]==\"suffix\" then 0 else 1 end),.[2]]) |
       group_by([.[0],.[2]])[] | sort_by([(.[1]|ascii_downcase),.[1]])[]) | @tsv" "$CONFIG_FILE")
    while IFS=$'\t' read -r selected_match selected_domain selected_outbound; do
      [[ -n $selected_domain ]] || continue
      rule_matches+=("$selected_match"); rule_domains+=("$selected_domain"); rule_outbounds+=("$selected_outbound")
    done <<<"$row"
    ((${#rule_domains[@]})) || { warn "没有可删除的域名分流规则。"; return 0; }
    printf '\n入站：%s\n\n' "$selected_inbound"
    for ((idx=0; idx<${#rule_domains[@]}; idx++)); do printf '%d) %s\n' "$((idx+1))" "${rule_domains[$idx]}"; done
    while true; do
      read -r -p '请选择要删除的规则（支持 1,3,2）: ' selection || return 0
      selection=$(printf '%s' "$selection" | tr -d '[:space:]'); requested=()
      IFS=',' read -r -a tokens <<<"$selection"; local valid=1
      for token in "${tokens[@]}"; do
        if [[ ! $token =~ ^[0-9]+$ ]] || ((10#$token < 1 || 10#$token > ${#rule_domains[@]})); then valid=0; break; fi
        idx=$((10#$token))
        if ((${#requested[@]})); then
          for choice in "${requested[@]}"; do ((choice != idx)) || { valid=0; break 2; }; done
        fi
        requested+=("$idx")
      done
      ((valid)) && ((${#requested[@]})) && break
      warn "请输入有效且不重复的序号，例如 1,3,2。"
    done
    printf '\n将删除：\n'
    for choice in "${requested[@]}"; do
      idx=$((choice-1)); [[ ${rule_matches[$idx]} == suffix ]] && match_label=子域名 || match_label=精确
      display=$(_outbound_display_name "${rule_outbounds[$idx]}")
      printf -- '- %s（%s → %s）\n' "${rule_domains[$idx]}" "$match_label" "$display"
      selected_json=$(jq -c --arg match "${rule_matches[$idx]}" --arg domain "${rule_domains[$idx]}" \
        '. + [{match:$match,domain:$domain}]' <<<"$selected_json")
    done
    confirm "确认删除这些规则？" N || return 0
  fi

  tmp=$(temp_file)
  jq --arg inbound "$selected_inbound" --argjson selected "$selected_json" --argjson owned "$owned" "$(_sbctl_managed_domain_rule_filter)
    def template_owned:
      (. as \$rule | any(\$owned[]; .inbound==\$rule.inbound[0] and
        ((.match==\"suffix\" and \$rule.domain_suffix==[.domain]) or
         (.match==\"exact\" and \$rule.domain==[.domain]))));
    def selected_domain_rule(\$rule; \$selected):
      any(\$selected[]; . as \$target |
        (\$rule | if \$target.match==\"suffix\" then .domain_suffix else .domain end)==[\$target.domain]);
    .route=(.route // {}) |
    .route.rules=[(.route.rules // [])[]? | (.) as \$rule |
      select(((\$rule | sbctl_managed_domain_rule) and (\$rule | template_owned | not) and
        \$rule.inbound==[\$inbound] and selected_domain_rule(\$rule;\$selected)) | not)]
  " "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then
    if [[ -n $match ]]; then info "已删除域名规则：${selected_inbound} ${match} ${domain}。"
    else info "已删除 ${#requested[@]} 条域名规则（入站：${selected_inbound}）。"; fi
  fi
  rm -f "$tmp"
}

delete_outbound() {
  ensure_dependencies outbound-delete; require_supported_core; ensure_config; init_meta
  local tag=${1-} answer item tmp manual_refs default_refs domain_refs binding_refs metadata_candidate="" owned_records removed_managed
  if [[ -z $tag ]]; then
    local tags=()
    while IFS= read -r item; do [[ -n $item ]] && tags+=("$item"); done < <(jq -r '.outbounds[]?|select(.type=="socks" or .type=="http")|.tag' "$CONFIG_FILE")
    ((${#tags[@]})) || { warn "没有可删除的代理出站。"; return 0; }
    if ((${#tags[@]} == 1)); then tag=${tags[0]}; else choose answer "选择出站" "${tags[@]}" || return 0; tag=${tags[$((answer-1))]}; fi
  fi
  [[ $tag != direct ]] || { warn "direct 出站不能删除。"; return 0; }
  outbound_exists "$tag" || die "找不到出站：$tag"
  manual_refs=$(jq -r --arg tag "$tag" "$(_sbctl_managed_domain_rule_filter)
    $(_sbctl_canonical_default_rule_filter)
    [.route.rules[]? | select(.outbound==\$tag) |
      select((sbctl_canonical_default_rule or sbctl_managed_domain_rule) | not)] | length" "$CONFIG_FILE")
  ((manual_refs == 0)) || { warn "该出站仍被自定义路由规则引用，请先在完整配置中处理。"; return 0; }
  default_refs=$(jq -r --arg tag "$tag" "$(_sbctl_canonical_default_rule_filter)
    [.route.rules[]? | select(sbctl_canonical_default_rule and .outbound==\$tag)] | length" "$CONFIG_FILE")
  domain_refs=$(jq -r --arg tag "$tag" "$(_sbctl_managed_domain_rule_filter)
    [.route.rules[]? | select(sbctl_managed_domain_rule and .outbound==\$tag)] | length" "$CONFIG_FILE")
  binding_refs=$(jq -r --arg tag "$tag" '[.domainTemplates.bindings[]? | select(.outbound==$tag)] | length' "$META_FILE")
  if ((default_refs > 0 || domain_refs > 0 || binding_refs > 0)); then
    printf '出站 %s 当前被：\n' "$tag"
    ((default_refs > 0)) && printf '%s 个入站默认出站使用\n' "$default_refs"
    ((domain_refs > 0)) && printf '%s 条域名规则使用\n' "$domain_refs"
    ((binding_refs > 0)) && printf '%s 个模板绑定使用\n' "$binding_refs"
    printf '删除后：\n'
    ((default_refs > 0)) && printf '%s 个默认绑定恢复 direct\n' "$default_refs"
    ((domain_refs > 0)) && printf '%s 条域名规则会一并删除\n' "$domain_refs"
    ((binding_refs > 0)) && printf '%s 个模板绑定会一并移除\n' "$binding_refs"
  fi
  confirm "删除出站 ${tag}？" N || return 0
  tmp=$(temp_file)
  jq --arg tag "$tag" '
    .outbounds |= map(select(.tag!=$tag)) |
    .route.rules = ((.route.rules // []) | map(select(.outbound!=$tag)))' "$CONFIG_FILE" >"$tmp"
  if ((binding_refs > 0)); then
    metadata_candidate=$(temp_file)
    owned_records=$(jq -c '.domainTemplates.managed // []' "$META_FILE")
    removed_managed=$(jq -c --arg tag "$tag" --argjson owned "$owned_records" '
      [.route.rules[]? | select(.outbound==$tag) | . as $rule |
       $owned[] | select(.inbound==$rule.inbound[0] and
         ((.match=="suffix" and $rule.domain_suffix==[.domain]) or
          (.match=="exact" and $rule.domain==[.domain])))]' "$CONFIG_FILE")
    jq --arg tag "$tag" --argjson removed "$removed_managed" '
      .domainTemplates=(.domainTemplates // {templates:[],bindings:[]}) |
      .domainTemplates.bindings=[.domainTemplates.bindings[]? | select(.outbound!=$tag)] |
      .domainTemplates.managed=[.domainTemplates.managed[]? | . as $item |
        select(any($removed[]; .inbound==$item.inbound and .match==$item.match and .domain==$item.domain) | not)]
    ' "$META_FILE" >"$metadata_candidate"
    if apply_candidate_with_meta "$tmp" "$metadata_candidate"; then info "出站 ${tag} 已删除。"; fi
  else
    if apply_candidate "$tmp"; then info "出站 ${tag} 已删除。"; fi
  fi
  rm -f "$tmp" "$metadata_candidate"
}

# ---- outbound overview display (from layout.sh) ----
