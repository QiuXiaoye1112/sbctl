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
  local ip=$1 tag tmp bind_field
  tag=$(_local_tag_for_ip "$ip")
  outbound_exists "$tag" && { printf '%s' "$tag"; return 0; }
  # sing-box uses inet4_bind_address / inet6_bind_address
  if [[ $ip == *:* ]]; then bind_field=inet6_bind_address; else bind_field=inet4_bind_address; fi
  tmp=$(temp_file)
  jq --arg tag "$tag" --arg ip "$ip" --arg field "$bind_field" \
    '.outbounds += [{type:"direct",tag:$tag} + {($field):$ip}]' \
    "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp" >&2; then
    printf '%s' "$tag"
  else
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
}

is_managed_inbound_route_rule() {
  local inbound=$1
  jq -e --arg inbound "$inbound" '
    type=="object" and .action=="route" and (.inbound // [])==[$inbound] and
    ((keys_unsorted | sort) == (["action","inbound","outbound"] | sort))' >/dev/null
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

list_outbound_overview() {
  ensure_config
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
  [[ -n $inbound ]] || select_inbound inbound || return
  inbound_exists "$inbound" || die "找不到入站：$inbound"
  [[ -n $outbound ]] || select_outbound outbound 1 || return
  [[ $outbound == direct ]] || outbound_exists "$outbound" || die "找不到出站：$outbound"

  tmp=$(temp_file)
  jq --arg inbound "$inbound" --arg outbound "$outbound" '
    .route = (.route // {}) |
    .route.rules = ((.route.rules // []) | map(
      select(.action!="route" or (.inbound // [])!=[$inbound] or
        ((keys_unsorted | sort) != (["action","inbound","outbound"] | sort))))) |
    if $outbound=="direct" then .
    else .route.rules = ([{inbound:[$inbound],action:"route",outbound:$outbound}] + .route.rules) end' \
    "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then info "入站 ${inbound} 已设置为出站 ${outbound}。"; fi
  rm -f "$tmp"
}

delete_outbound() {
  ensure_dependencies outbound-delete; require_supported_core; ensure_config
  local tag=${1-} answer item tmp manual_refs
  if [[ -z $tag ]]; then
    local tags=()
    while IFS= read -r item; do [[ -n $item ]] && tags+=("$item"); done < <(jq -r '.outbounds[]?|select(.type=="socks" or .type=="http")|.tag' "$CONFIG_FILE")
    ((${#tags[@]})) || { warn "没有可删除的代理出站。"; return 0; }
    if ((${#tags[@]} == 1)); then tag=${tags[0]}; else choose answer "选择出站" "${tags[@]}"; tag=${tags[$((answer-1))]}; fi
  fi
  [[ $tag != direct ]] || die "direct 出站不能删除。"
  outbound_exists "$tag" || die "找不到出站：$tag"
  manual_refs=$(jq -r --arg tag "$tag" '[.route.rules[]? | select(.outbound==$tag) | select((.action=="route" and ((.inbound//[])|length)==1 and ((keys_unsorted|sort)==(["action","inbound","outbound"]|sort))) | not)] | length' "$CONFIG_FILE")
  ((manual_refs == 0)) || die "该出站仍被自定义路由规则引用，请先在完整配置中处理。"
  confirm "删除出站 ${tag}？使用它的 sbctl 入站绑定会恢复 direct。" N || return
  tmp=$(temp_file)
  jq --arg tag "$tag" '
    .outbounds |= map(select(.tag!=$tag)) |
    .route.rules = ((.route.rules // []) | map(select(.outbound!=$tag)))' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then info "出站 ${tag} 已删除。"; fi
  rm -f "$tmp"
}
