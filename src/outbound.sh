outbound_exists() {
  jq -e --arg tag "$1" '.outbounds[]?|select(.tag==$tag)' "$CONFIG_FILE" >/dev/null
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
    while IFS= read -r line; do
      iface=$(awk '{print $1}' <<<"$line" | sed 's/:$//')
      ip=$(awk '{print $2}' <<<"$line")
      validate_ipv4 "$ip" || continue
      [[ $ip =~ ^127\. ]] && continue
      printf '%s (IPv4)\t%s\t%s\n' "$ip" "$ip" "$iface"
    done < <(ifconfig 2>/dev/null | grep 'inet ' | grep -v '127\.')
    while IFS= read -r line; do
      iface=$(awk '{print $1}' <<<"$line" | sed 's/:$//')
      ip=$(awk '{print $2}' <<<"$line")
      ip=${ip%%%*}
      [[ -z $ip || $ip == ::1 || $ip == fe80:* ]] && continue
      printf '%s (IPv6)\t%s\t%s\n' "$ip" "$ip" "$iface"
    done < <(ifconfig 2>/dev/null | grep 'inet6 ' | grep -v '::1\|fe80:')
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

_outbound_display_name() {
  local tag=$1 ip
  [[ $tag == direct ]] && { printf 'direct'; return; }
  ip=$(jq -r --arg tag "$tag" '.outbounds[]?|select(.tag==$tag)|(.inet4_bind_address // .inet6_bind_address // empty)' "$CONFIG_FILE" 2>/dev/null || true)
  printf '%s' "${ip:-$tag}"
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

# Pure display — only sbctl's strict canonical domain rules are shown.
list_domain_rules() {
  ensure_dependencies outbound-rule-list; ensure_config
  local inbound=${1-} row number=0 match domain outbound display
  [[ -z $inbound ]] || inbound_exists "$inbound" || die "找不到入站：$inbound"
  row=$(jq -r --arg inbound "$inbound" "$(_sbctl_managed_domain_rule_filter)
    [.route.rules[]? |
      select(sbctl_managed_domain_rule) |
      select(\$inbound==\"\" or .inbound==[\$inbound]) |
      .inbound[0] as \$rule_inbound |
      (if has(\"domain_suffix\") then \"suffix\" else \"exact\" end) as \$match |
      (if \$match==\"suffix\" then .domain_suffix[0] else .domain[0] end) as \$domain |
      [\$rule_inbound,\$match,\$domain,.outbound] | @tsv] | .[]" "$CONFIG_FILE")
  heading "域名分流规则"
  [[ -n $row ]] || { info "还没有域名分流规则。"; return 0; }
  print_table_cell "序号" 6; printf '| '
  print_table_cell_clipped "入站" 14; printf '| '
  print_table_cell "匹配" 6; printf '| '
  print_table_cell_clipped "域名" 18; printf '| 出站\n'
  while IFS=$'\t' read -r inbound match domain outbound; do
    [[ -n $inbound ]] || continue
    ((number+=1))
    display=$(_outbound_display_name "$outbound")
    [[ $match == suffix ]] && match="子域名" || match="精确"
    print_table_cell "$number" 6; printf '| '
    print_table_cell_clipped "$inbound" 14; printf '| '
    print_table_cell "$match" 6; printf '| '
    print_table_cell_clipped "$domain" 18; printf '| %s\n' "$display"
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
      local display="$outbound"
      if [[ $outbound =~ ^local- ]]; then
        local ip; ip=$(jq -r --arg tag "$outbound" '.outbounds[]?|select(.tag==$tag)|(.inet4_bind_address // .inet6_bind_address // empty)' "$CONFIG_FILE" 2>/dev/null || true)
        display="${ip:-$outbound}"
      fi
      print_table_cell_clipped "$inbound" 26; printf '| %s\n' "$display"
    done < <(jq -r '.inbounds[].tag' "$CONFIG_FILE")
  fi

  heading "SOCKS5 / HTTP 出站"
  if ! jq -e '.outbounds[]?|select(.type=="socks" or .type=="http")' "$CONFIG_FILE" >/dev/null; then
    info "还没有代理出站。"
    return 0
  fi
  print_table_cell "序号" 6; printf '| '
  print_table_cell_clipped "标签" 22; printf '| '
  print_table_cell "协议" 8; printf '| '
  print_table_cell_clipped "地址" 26; printf '| 用户\n'
  while IFS=$'\t' read -r outbound type server port user; do
    ((number+=1))
    print_table_cell "$number" 6; printf '| '
    print_table_cell_clipped "$outbound" 22; printf '| '
    print_table_cell "$type" 8; printf '| '
    print_table_cell_clipped "$(uri_host "$server"):${port}" 26; printf '| %s\n' "${user:-无}"
  done < <(jq -r '.outbounds[]?|select(.type=="socks" or .type=="http")|[.tag,.type,.server,(.server_port|tostring),(.username//"")]|@tsv' "$CONFIG_FILE")
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
      if ((found)); then display_labels+=("${dlabel}"); else display_labels+=("$t"); fi
    else
      local stype; stype=$(jq -r --arg tag "$t" '.outbounds[]?|select(.tag==$tag)|.type' "$CONFIG_FILE" 2>/dev/null || printf '?')
      local saddr; saddr=$(jq -r --arg tag "$t" '.outbounds[]?|select(.tag==$tag)|"\(.server // "?"):\(.server_port // "?")"' "$CONFIG_FILE" 2>/dev/null || printf '?:?')
      display_labels+=("$t ($stype · $saddr)")
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
    selected=$(_ensure_local_outbound "$ip") || { error "无法创建本地出口。"; return 1; }
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
  local inbound=${1-} match=${2-} domain=${3-} outbound=${4-} choice tmp new_rule normalized_domain
  local interactive=0
  [[ -n $inbound || -n $match || -n $domain || -n $outbound ]] && interactive=1
  if ((interactive)); then
    [[ -n $inbound && -n $match && -n $domain && -n $outbound ]] || \
      die "用法：sbctl outbound rule add [入站] [suffix|exact] [域名] [出站]"
    inbound_exists "$inbound" || die "找不到入站：$inbound"
    case $match in
      suffix|exact) ;;
      *) die "匹配方式只能是 suffix 或 exact。";;
    esac
    _normalize_domain_input normalized_domain "$domain" || die "域名格式无效。"
    domain=$normalized_domain
    [[ $outbound == direct ]] || outbound_exists "$outbound" || die "找不到出站：$outbound"
  else
    select_inbound inbound || return 0
    choose choice "匹配方式" "域名及所有子域名" "仅精确域名" || return 0
    [[ $choice == 1 ]] && match=suffix || match=exact
    while true; do
      prompt_value domain "域名" || return 0
      if _normalize_domain_input normalized_domain "$domain"; then domain=$normalized_domain; break; fi
    done
    select_outbound outbound 1 || return 0
  fi

  new_rule=$(jq -n --arg inbound "$inbound" --arg match "$match" --arg domain "$domain" --arg outbound "$outbound" '
    {inbound:[$inbound]} +
    (if $match=="suffix" then {domain_suffix:[$domain]} else {domain:[$domain]} end) +
    {action:"route",outbound:$outbound}')
  tmp=$(temp_file)
  jq --arg inbound "$inbound" --arg match "$match" --arg domain "$domain" --arg outbound "$outbound" \
    --argjson new_rule "$new_rule" "$(_sbctl_managed_domain_rule_filter)
    $(_sbctl_canonical_default_rule_filter)
    $(_sbctl_domain_rule_insert_filter)
    def sbctl_current_domain_rule:
      sbctl_managed_domain_rule and .inbound==[\$inbound];
    def sbctl_target_domain_rule:
      sbctl_current_domain_rule and
      ((if \$match==\"suffix\" then .domain_suffix else .domain end)==[\$domain]);
    .route=(.route // {}) |
    (.route.rules // []) as \$rules |
    (reduce \$rules[] as \$rule
      ({items:[],replaced:false};
       if (\$rule | sbctl_target_domain_rule) then
         if .replaced then .
         else .items += [\$rule | .outbound=\$outbound] | .replaced=true
         end
       else .items += [\$rule]
       end)) as \$updated |
    if \$updated.replaced then
      .route.rules=\$updated.items
    else
      (\$rules | sbctl_domain_insert_index(\$rules; \$inbound; \$match; \$domain)) as \$index |
      .route.rules=sbctl_insert_rule(\$rules; \$index; \$new_rule)
    end" "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then info "已添加/更新域名规则：${inbound} ${match} ${domain} -> ${outbound}。"; fi
  rm -f "$tmp"
}

delete_domain_rule() {
  ensure_dependencies outbound-rule-delete; require_supported_core; ensure_config
  local inbound=${1-} row choice selected_inbound selected_match selected_domain selected_outbound tmp
  local -a rule_inbounds=() rule_matches=() rule_domains=() rule_outbounds=() labels=()
  [[ -z $inbound ]] || inbound_exists "$inbound" || die "找不到入站：$inbound"
  row=$(jq -r --arg inbound "$inbound" "$(_sbctl_managed_domain_rule_filter)
    [.route.rules[]? |
      select(sbctl_managed_domain_rule) |
      select(\$inbound==\"\" or .inbound==[\$inbound]) |
      .inbound[0] as \$rule_inbound |
      (if has(\"domain_suffix\") then \"suffix\" else \"exact\" end) as \$match |
      (if \$match==\"suffix\" then .domain_suffix[0] else .domain[0] end) as \$domain |
      [\$rule_inbound,\$match,\$domain,.outbound] | @tsv] | .[]" "$CONFIG_FILE")
  [[ -n $row ]] || { warn "没有可删除的域名分流规则。"; return 0; }
  while IFS=$'\t' read -r selected_inbound selected_match selected_domain selected_outbound; do
    [[ -n $selected_inbound ]] || continue
    rule_inbounds+=("$selected_inbound")
    rule_matches+=("$selected_match")
    rule_domains+=("$selected_domain")
    rule_outbounds+=("$selected_outbound")
    labels+=("${selected_inbound} · ${selected_match} · ${selected_domain} → $(_outbound_display_name "$selected_outbound")")
  done <<<"$row"
  ((${#rule_inbounds[@]})) || { warn "没有可删除的域名分流规则。"; return 0; }
  if ((${#rule_inbounds[@]} == 1)); then
    choice=1
  else
    choose choice "选择要删除的域名规则" "${labels[@]}" || return 0
  fi
  selected_inbound=${rule_inbounds[$((choice-1))]}
  selected_match=${rule_matches[$((choice-1))]}
  selected_domain=${rule_domains[$((choice-1))]}
  tmp=$(temp_file)
  jq --arg inbound "$selected_inbound" --arg match "$selected_match" --arg domain "$selected_domain" "$(_sbctl_managed_domain_rule_filter)
    .route=(.route // {}) |
    .route.rules=[(.route.rules // [])[]? |
      select((sbctl_managed_domain_rule and .inbound==[\$inbound] and
        ((if \$match==\"suffix\" then .domain_suffix else .domain end)==[\$domain])) | not)]" \
    "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then info "已删除域名规则：${selected_inbound} ${selected_match} ${selected_domain}。"; fi
  rm -f "$tmp"
}

delete_outbound() {
  ensure_dependencies outbound-delete; require_supported_core; ensure_config
  local tag=${1-} answer item tmp manual_refs default_refs domain_refs
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
  if ((default_refs > 0 || domain_refs > 0)); then
    printf '出站 %s 当前被：\n' "$tag"
    ((default_refs > 0)) && printf '%s 个入站默认出站使用\n' "$default_refs"
    ((domain_refs > 0)) && printf '%s 条域名规则使用\n' "$domain_refs"
    printf '删除后：\n'
    ((default_refs > 0)) && printf '%s 个默认绑定恢复 direct\n' "$default_refs"
    ((domain_refs > 0)) && printf '%s 条域名规则会一并删除\n' "$domain_refs"
  fi
  confirm "删除出站 ${tag}？" N || return 0
  tmp=$(temp_file)
  jq --arg tag "$tag" '
    .outbounds |= map(select(.tag!=$tag)) |
    .route.rules = ((.route.rules // []) | map(select(.outbound!=$tag)))' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then info "出站 ${tag} 已删除。"; fi
  rm -f "$tmp"
}

# ---- outbound overview display (from layout.sh) ----
