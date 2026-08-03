outbound_exists() {
  jq -e --arg tag "$1" '.outbounds[]?|select(.tag==$tag)' "$CONFIG_FILE" >/dev/null
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
      print_table_cell_clipped "$inbound" 26; printf '| %s\n' "$outbound"
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
  local tags=()
  ((include_direct == 0)) || tags+=(direct)
  while IFS= read -r item; do [[ -n $item ]] && tags+=("$item"); done < <(
    jq -r '.outbounds[]?|select(.type=="socks" or .type=="http")|.tag' "$CONFIG_FILE"
  )
  ((${#tags[@]})) || { warn "没有可选出站。"; return 1; }
  choose answer "选择出站" "${tags[@]}"
  selected=${tags[$((answer-1))]}
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
