# shellcheck shell=bash
# sbctl inbound — canonical inbound CRUD with transactional meta updates.
# Uses a single jq call per display page.

inbound_exists() { jq -e --arg tag "$1" '.inbounds[]?|select(.tag==$tag)' "$CONFIG_FILE" >/dev/null; }
inbound_listen() {
  jq -r --arg tag "$1" '.inbounds[]? | select(.tag==$tag) | .listen // "::"' "$CONFIG_FILE"
}

# Treat legacy wildcards as overlapping either family, like their firewall rules.
listener_addresses_overlap() {
  local first second
  first=$(normalize_socket_ip "$1") || first='*'
  second=$(normalize_socket_ip "$2") || second='*'
  case $first in 0.0.0.0|::|'*') return 0;; esac
  case $second in 0.0.0.0|::|'*') return 0;; esac
  [[ $first == "$second" ]]
}

port_in_config() {
  local port=$1 except=${2-} address=${3:-::} rows bound
  rows=$(jq -r --argjson port "$port" --arg except "$except" '
    .inbounds[]? | select(.listen_port==$port and .tag!=$except) | .listen // "::"
  ' "$CONFIG_FILE") || return 0
  while IFS= read -r bound; do
    [[ -n $bound ]] && listener_addresses_overlap "$address" "$bound" && return 0
  done <<<"$rows"
  return 1
}

port_in_use_os() {
  local port=$1 address=${2:-::} except=${3-} transport=${4-} endpoints endpoint details bound bound_port
  local old_address="" old_port="" own_binary=${SING_BOX_BIN##*/}
  if command_exists ss && endpoints=$(ss -H -lntupe 2>/dev/null || ss -H -lntup 2>/dev/null); then
    endpoints=$(awk '{print $5 "\t" $0}' <<<"$endpoints")
  elif command_exists netstat && endpoints=$(netstat -lntup 2>/dev/null || netstat -lntu 2>/dev/null); then
    endpoints=$(awk '$1 ~ /^(tcp|udp)/ {print $4 "\t" $0}' <<<"$endpoints")
  else
    return 1
  fi
  if [[ -n $except ]] && service_is_active; then
    old_address=$(inbound_listen "$except")
    old_port=$(jq -r --arg tag "$except" '.inbounds[]?|select(.tag==$tag)|.listen_port' "$CONFIG_FILE")
  fi
  while IFS=$'\t' read -r endpoint details; do
    [[ -z $transport || $details == "$transport"[[:space:]]* || $details == "${transport}6"[[:space:]]* ]] || continue
    bound_port=${endpoint##*:}
    if [[ $port == *-* ]]; then
      hy2_port_in_range "$bound_port" "$port" || continue
    else
      [[ $bound_port == "$port" ]] || continue
    fi
    bound=${endpoint%:*}; bound=${bound#\[}; bound=${bound%\]}; bound=${bound%%%*}
    if [[ $bound_port == "$old_port" && ( $details == *\""$own_binary"\"* || $details == *"/$own_binary" ) ]]; then
      if [[ $(normalize_socket_ip "$bound" || printf '*') == "$(normalize_socket_ip "$old_address")" ]] ||
         { [[ $bound == '*' || $bound == :: || $bound == 0.0.0.0 ]] &&
           [[ $old_address == 0.0.0.0 || $old_address == :: ]]; }; then
        continue
      fi
    fi
    if [[ $bound == 0.0.0.0 && $address == *:* && $address != :: ]] ||
       { [[ $bound == :: || $bound == '*' ]] && [[ $details == *v6only:1* && $address != *:* && $address != 0.0.0.0 ]]; }; then
      continue
    fi
    listener_addresses_overlap "$address" "$bound" && return 0
  done <<<"$endpoints"
  return 1
}

prompt_tag() {
  local __var=$1 default=$2 value
  while true; do
    prompt_value value "入站标签" "$default" || return 1
    validate_tag "$value" || { warn "标签只能包含字母、数字、点、下划线和横线。"; continue; }
    inbound_exists "$value" && { warn "标签已存在。"; continue; }
    printf -v "$__var" '%s' "$value"; return
  done
}
_random_port_avoiding_hops() {
  local candidate hex i
  for ((i=0; i<64; i++)); do
    hex=$(random_hex 2)
    candidate=$((10000 + (16#$hex % 55536)))
    hy2_port_in_default_hop_range "$candidate" && continue
    hy2_port_in_any_hop_range "$candidate" && continue
    port_in_config "$candidate" && continue
    port_in_use_os "$candidate" && continue
    printf '%s' "$candidate"; return 0
  done
  for ((candidate=10000; candidate<=65535; candidate++)); do
    hy2_port_in_default_hop_range "$candidate" && continue
    hy2_port_in_any_hop_range "$candidate" && continue
    port_in_config "$candidate" && continue
    port_in_use_os "$candidate" && continue
    printf '%s' "$candidate"; return 0
  done
  return 1
}

prompt_port() {
  local __var=$1 default=${2:-$(_random_port_avoiding_hops)} except=${3-} address=${4:-::} type=${5-} value
  while true; do
    prompt_value value "监听端口" "$default" || return 1
    validate_port "$value" || { warn "端口必须为 1-65535。"; continue; }
    value=$((10#$value))
    port_in_config "$value" "$except" "$address" && { warn "该地址的端口已被其他入站使用。"; continue; }
    port_in_use_os "$value" "$address" "$except" && { warn "该地址的端口已被占用。"; continue; }
    if [[ $type == hysteria2 || $type == socks ]] && hy2_port_in_any_hop_range "$value" "$address"; then
      warn "该端口已被此地址的 Hysteria2 跳跃范围覆盖。"
      continue
    fi
    printf -v "$__var" '%s' "$value"; return
  done
}

prompt_inbound_ip() {
  local __out=$1 local_ip canonical family_choice=1 ip_choice
  local label=${2:-选择要绑定的本机} network_v4=0 network_v6=0
  local -a addresses_v4=() addresses_v6=()
  local -A seen=()
  while IFS=$'\t' read -r _ local_ip _; do
    [[ -n $local_ip ]] || continue
    canonical=$(normalize_socket_ip "$local_ip") || continue
    case $canonical in 0.0.0.0|::|fe[89ab][0-9a-f]:*) continue;; esac
    [[ -z ${seen[$canonical]+x} ]] || continue
    seen[$canonical]=1
    if [[ $canonical == *:* ]]; then
      addresses_v6+=("$local_ip")
      if [[ $canonical != 0000:0000:0000:0000:0000:0000:0000:0001 ]]; then network_v6=1; fi
    else
      addresses_v4+=("$canonical")
      if [[ $canonical != 127.* ]]; then network_v4=1; fi
    fi
  done < <(detect_local_ips inbound)

  # A loopback address alone does not make the other family available to clients.
  if ((network_v4 || network_v6)); then
    if ((network_v4 == 0)); then addresses_v4=(); fi
    if ((network_v6 == 0)); then addresses_v6=(); fi
  fi

  if ((${#addresses_v4[@]} == 0 && ${#addresses_v6[@]} == 0)); then
    warn "未检测到可绑定的本机 IPv4 或 IPv6 地址。"
    return 1
  fi
  if ((${#addresses_v4[@]} > 0 && ${#addresses_v6[@]} > 0)); then
    choose family_choice "选择客户端连接地址类型" "IPv4" "IPv6" || return 1
  elif ((${#addresses_v4[@]} == 0)); then
    family_choice=2
  fi

  if ((family_choice == 1)); then
    choose ip_choice "${label} IPv4" "${addresses_v4[@]}" || return 1
    printf -v "$__out" '%s' "${addresses_v4[$((ip_choice-1))]}"
  else
    choose ip_choice "${label} IPv6" "${addresses_v6[@]}" || return 1
    printf -v "$__out" '%s' "${addresses_v6[$((ip_choice-1))]}"
  fi
}

build_inbound() {
  local __json=$1 __host=$2 __public=$3 __hop=${4-} choice type tag listen port client_host="" tls="" reality_public="" name="" password="" uuid="" flow="" obfs_choice="" obfs_password="" up="" down="" selected_hop_range="" transport_json="null" ws_path=""
  choose choice "选择入站协议" "AnyTLS" "Hysteria2" "SOCKS5" "HTTP" || return 1
  case $choice in 1) type=anytls;; 2) type=hysteria2;; 3) type=socks;; 4) type=http;; esac
  ui_section "监听与连接"
  prompt_tag tag "${type}-$(random_hex 2)" || return 1
  prompt_inbound_ip listen || return 1
  client_host=$listen

  case $type in
    anytls)
      choose choice "选择 TLS 安全层" "REALITY" "证书 TLS" || return 1
      if [[ $choice == 1 ]]; then
        build_reality_tls tls reality_public || return 1
      else
        build_certificate_tls tls || return 1
      fi
      prompt_port port "" "" "$listen" "$type" || return 1
      ;;
    hysteria2)
      build_certificate_tls tls || return 1
      local hop_choice
      choose hop_choice "端口模式" "普通端口" "端口跳跃" || return 1
      if [[ $hop_choice == 2 ]]; then
        while true; do
          prompt_value selected_hop_range "端口跳跃范围" "30000-50000" || return 1
          validate_hy2_hop_range "$selected_hop_range" && break
          warn "格式：起始端口-结束端口，起始端口必须小于结束端口。"
        done
        if ! hy2_hop_check_conflicts "$selected_hop_range" "$tag" "$listen"; then
          return 1
        fi
        prompt_hy2_internal_port port "$selected_hop_range" "$listen" || return 1
      else
        prompt_port port "" "" "$listen" "$type" || return 1
      fi
      ;;
    socks|http)
      prompt_port port "" "" "$listen" "$type" || return 1
      ;;
  esac

  ui_section "用户与认证"
  case $type in
    anytls)
      prompt_value name "用户名称" "user-$(random_hex 2)" || return 1
      prompt_secret password "AnyTLS 密码" "$(random_password)" || return 1
      protocol_build_anytls "$__json" "$tag" "$listen" "$port" "$name" "$password" "$tls"
      ;;
    hysteria2)
      prompt_value name "用户名称" "user-$(random_hex 2)" || return 1
      prompt_secret password "Hysteria2 密码" "$(random_password)" || return 1
      prompt_optional_positive_int up "上行限制 Mbps（留空=不限）" || return 1
      prompt_optional_positive_int down "下行限制 Mbps（留空=不限）" || return 1
      choose obfs_choice "QUIC 混淆" "关闭" "Salamander" || return 1
      if [[ $obfs_choice == 2 ]]; then prompt_secret obfs_password "混淆密码" "$(random_password)" || return 1; fi
      hy2_build "$__json" "$tag" "$listen" "$port" "$name" "$password" "$up" "$down" "$obfs_password" "$tls"
      ;;
    socks|http)
      prompt_optional name "用户名（留空=无认证）" || return 1
      if [[ -n $name ]]; then prompt_secret password "密码" "$(random_password)" || return 1; fi
      [[ -n $name || $listen == 127.0.0.1 || $listen == ::1 ]] || warn "公网无认证代理风险很高。"
      protocol_build_proxy "$__json" "$type" "$tag" "$listen" "$port" "$name" "$password"
      ;;
  esac
  printf -v "$__host" '%s' "$client_host"
  printf -v "$__public" '%s' "$reality_public"
  [[ -z $__hop ]] || printf -v "$__hop" '%s' "$selected_hop_range"
}

# ---- inbound CRUD ----

add_inbound() {
  ensure_dependencies inbound-add; require_supported_core; ensure_config
  local inbound host public tag tmp meta_tmp rc=0 type hop_range
  build_inbound inbound host public hop_range || return 0
  tag=$(jq -r '.tag' <<<"$inbound")
  type=$(jq -r '.type' <<<"$inbound")
  tmp=$(temp_file); meta_tmp=$(temp_file)
  jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" >"$tmp"
  build_inbound_meta_candidate "$tag" "$host" "$public" "$tmp" "$meta_tmp"
  # If port hopping was selected during build, stamp metadata before apply
  if [[ $type == hysteria2 && -n $hop_range ]]; then
    local meta_tmp2
    meta_tmp2=$(temp_file)
    jq --arg tag "$tag" --arg range "$hop_range" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
      .inbounds[$tag]=((.inbounds[$tag]//{})+{updatedAt:$now}) |
      .inbounds[$tag].hysteria2PortHopping={enabled:true,range:$range}' "$meta_tmp" >"$meta_tmp2"
    rm -f "$meta_tmp"
    meta_tmp=$meta_tmp2
  fi
  if apply_candidate_with_meta "$tmp" "$meta_tmp" 1; then
    if [[ -n $hop_range ]]; then
      info "Hysteria2 端口跳跃已启用：${hop_range} -> UDP $(jq -r '.listen_port' <<<"$inbound")"
    fi
    heading "入站已创建"
    show_inbound "$tag"
    print_share "$tag" "" || true
  else
    rc=$?
  fi
  rm -f "$tmp" "$meta_tmp"
  return "$rc"
}

ui_inbound_rows() {
  local rows=$1 columns tag type port security transport users display_tag
  columns=$(ui_width)
  if ((columns >= 64)); then
    printf '  %s' "$C_DIM"
    print_table_cell "标签" 18
    print_table_cell "协议" 12
    print_table_cell "端口" 7
    print_table_cell "安全" 10
    print_table_cell "传输" 8
    printf '用户%s\n' "$C_RESET"
  fi
  while IFS=$'\t' read -r tag type port security transport users; do
    type=$(protocol_display_name "$type" || printf '%s' "$type")
    if ((columns < 64)); then
      display_tag=$(print_table_cell_clipped "$tag" "$((columns > 8 ? columns - 4 : 4))")
      display_tag=${display_tag%"${display_tag##*[! ]}"}
      printf '  %s%s%s\n    %s · %s · %s\n    端口 %s · 用户 %s\n' \
        "$C_BOLD" "$display_tag" "$C_RESET" "$type" "$security" "$transport" "$port" "$users"
    else
      printf '  '
      print_table_cell_clipped "$tag" 16; printf '  '
      print_table_cell_clipped "$type" 10; printf '  '
      print_table_cell "$port" 5; printf '  '
      print_table_cell_clipped "$security" 8; printf '  '
      print_table_cell_clipped "$transport" 6; printf '  %s\n' "$users"
    fi
  done <<<"$rows"
}

# Single-jq list_inbounds — one jq call for the entire table.
# Does NOT call ensure_config/init_meta — callers must ensure config is valid.
list_inbounds() {
  [[ -f $CONFIG_FILE ]] || { info "还没有入站。"; return 0; }
  local rows tag_width=16 type_width=10 port_width=6 security_width=8 transport_width=7 users_width=4

  # One jq call: produces TSV, empty means no inbounds
  rows=$(jq -r '.inbounds[] | [.tag,.type,(.listen_port|tostring),(if .tls.reality.enabled==true then "reality" elif .tls.enabled==true then "tls" else "none" end),(.transport.type // (if .type=="hysteria2" then "quic" else "tcp" end)),((.users//[])|length|tostring)] | @tsv' "$CONFIG_FILE")
  if [[ -z $rows ]]; then info "还没有入站。"; return 0; fi
  if [[ ${1-} == --menu ]]; then ui_inbound_rows "$rows"; return; fi

  print_table_cell_clipped "标签" "$tag_width"; printf '| '
  print_table_cell_clipped "协议" "$type_width"; printf '| '
  print_table_cell "端口" "$port_width"; printf '| '
  print_table_cell_clipped "安全" "$security_width"; printf '| '
  print_table_cell_clipped "传输" "$transport_width"; printf '| '
  printf '用户\n'

  while IFS=$'\t' read -r tag type port security transport users; do
    print_table_cell_clipped "$tag" "$tag_width"; printf '| '
    print_table_cell_clipped "$type" "$type_width"; printf '| '
    print_table_cell "$port" "$port_width"; printf '| '
    print_table_cell_clipped "$security" "$security_width"; printf '| '
    print_table_cell_clipped "$transport" "$transport_width"; printf '| '
    printf '%s\n' "$users"
  done <<<"$rows"
}

show_inbound() {
  local tag=$1
  inbound_exists "$tag" || die "找不到入站：$tag"
  jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)' "$CONFIG_FILE"
}

select_inbound() {
  local __var=$1 filter=${2-} __item __answer __selected
  local tags=()
  ensure_config
  while IFS= read -r __item; do [[ -n $__item ]] && tags+=("$__item"); done < <(
    if [[ -n $filter ]]; then jq -r --arg re "$filter" '.inbounds[]|select(.type|test($re))|.tag' "$CONFIG_FILE"; else jq -r '.inbounds[].tag' "$CONFIG_FILE"; fi
  )
  ((${#tags[@]})) || { warn "没有可选入站。"; return 1; }
  if ((${#tags[@]} == 1)); then __selected=${tags[0]}; else choose __answer "选择入站" "${tags[@]}" || return 1; __selected=${tags[$((__answer-1))]}; fi
  printf -v "$__var" '%s' "$__selected"
}

delete_inbound() {
  ensure_dependencies inbound-delete; ensure_config
  local tag=${1-} yes=${2:-0} tmp meta_tmp rc=0
  [[ -n $tag ]] || select_inbound tag || return 0
  inbound_exists "$tag" || die "找不到入站：$tag"
  [[ $yes == 1 ]] || confirm "删除入站 ${tag}？" N || return 0
  tmp=$(temp_file); meta_tmp=$(temp_file); init_meta
  jq --arg tag "$tag" '
    .inbounds |= map(select(.tag!=$tag)) |
    .route.rules = [(.route.rules // [])[]? |
      if ((.inbound // null)|type)=="array" and ((.inbound // [])|index($tag))!=null then
        .inbound |= map(select(.!=$tag)) | select((.inbound|length)>0)
      elif (.inbound // null)==$tag then empty
      else . end]' "$CONFIG_FILE" >"$tmp"
  jq --arg tag "$tag" '
    del(.inbounds[$tag]) |
    .domainTemplates=(.domainTemplates // {templates:[],bindings:[]}) |
    .domainTemplates.bindings=[.domainTemplates.bindings[]? | select(.inbound!=$tag)] |
    .domainTemplates.managed=[.domainTemplates.managed[]? | select(.inbound!=$tag)]
  ' "$META_FILE" >"$meta_tmp"
  if apply_candidate_with_meta "$tmp" "$meta_tmp"; then
    hy2_hop_sync || { warn "入站已删除，但端口跳跃规则同步失败，请重试同步。"; rc=1; }
    traffic_after_config_change "$tag" || warn "流量统计规则未能同步，请在流量信息中刷新。"
    info "已删除入站 ${tag}。"
  else
    rc=$?
  fi
  rm -f "$tmp" "$meta_tmp"
  return "$rc"
}

modify_inbound_basic() {
  ensure_dependencies inbound-modify; ensure_config
  local tag=${1-} mode=${2:-both} listen port type old_listen old_port hop_range tmp meta_tmp="" rc=0
  [[ -n $tag ]] || select_inbound tag || return 0
  inbound_exists "$tag" || die "找不到入站：$tag"
  old_listen=$(inbound_listen "$tag") || return 1
  old_port=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen_port' "$CONFIG_FILE") || return 1
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE") || return 1
  listen=$old_listen; port=$old_port
  if [[ $mode != port ]]; then
    info "监听地址：$old_listen"
    prompt_inbound_ip listen || return 1
  fi
  if [[ $mode != address ]]; then
    prompt_port port "$old_port" "$tag" "$listen" "$type" || return 1
  elif port_in_config "$port" "$tag" "$listen" || port_in_use_os "$port" "$listen" "$tag"; then
    warn "该地址的端口已被占用。"
    return 1
  fi
  hop_range=$(hy2_hop_range_for_tag "$tag") || return 1
  if [[ -n $hop_range ]]; then
    hy2_hop_check_conflicts "$hop_range" "$tag" "$listen" || return 1
  fi
  if [[ $type == hysteria2 || $type == socks ]] && hy2_port_in_any_hop_range "$port" "$listen"; then
    warn "监听端口不能落在此地址的跳跃范围内。"
    return 1
  fi
  if [[ $listen == "$old_listen" && $port == "$old_port" ]] &&
     { [[ $mode == port ]] || [[ $listen == "$(jq -r --arg tag "$tag" '.inbounds[$tag].host // empty' "$META_FILE" 2>/dev/null)" ]]; }; then
    info "监听设置未更改。"
    return 0
  fi
  tmp=$(temp_file) || return 1
  if ! jq --arg tag "$tag" --arg listen "$listen" --arg mode "$mode" --argjson port "$port" '
    (.inbounds[] | select(.tag==$tag)) |=
      (if $mode=="port" then . else .listen=$listen end |
       if $mode=="address" then . else .listen_port=$port end)
  ' "$CONFIG_FILE" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if [[ $mode != port ]]; then
    init_meta
    meta_tmp=$(temp_file) || { rm -f "$tmp"; return 1; }
    if ! jq --arg tag "$tag" --arg listen "$listen" '.inbounds[$tag].host=$listen' "$META_FILE" >"$meta_tmp"; then
      rm -f "$tmp" "$meta_tmp"
      return 1
    fi
  fi
  apply_candidate_with_meta "$tmp" "$meta_tmp" 1 || rc=$?
  rm -f "$tmp"
  [[ -z $meta_tmp ]] || rm -f "$meta_tmp"
  return "$rc"
}

modify_inbound_certificate() {
  ensure_dependencies inbound-security; require_supported_core; ensure_config
  local tag=$1 tls tmp rc=0
  inbound_exists "$tag" || die "找不到入站：$tag"
  jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.enabled==true and (.tls.reality.enabled!=true)' "$CONFIG_FILE" >/dev/null || { error '该入站未使用证书 TLS。'; return 1; }
  build_certificate_tls tls || return 1
  tmp=$(temp_file) || return 1
  if ! jq --arg tag "$tag" --argjson tls "$tls" '(.inbounds[]|select(.tag==$tag)|.tls) |= (.certificate_path=$tls.certificate_path | .key_path=$tls.key_path | .server_name=$tls.server_name)' "$CONFIG_FILE" >"$tmp"; then
    rm -f "$tmp"; return 1
  fi
  if apply_candidate "$tmp"; then info "入站 ${tag} 的证书已更新。"; else rc=$?; fi
  rm -f "$tmp"
  return "$rc"
}

modify_inbound_security() {
  ensure_dependencies inbound-security; require_supported_core; ensure_config
  local tag=${1-} type choice tls="" public="" tmp meta_tmp host="" rc=0
  [[ -n $tag ]] || select_inbound tag || return 0
  inbound_exists "$tag" || die "找不到入站：$tag"
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
  case $type in
    anytls)
      choose choice "选择 TLS 安全层" "REALITY" "证书 TLS" || return 1
      if protocol_capability "$type" reality && [[ $choice == 1 ]]; then build_reality_tls tls public || return 1; else build_certificate_tls tls || return 1; fi
      ;;
    hysteria2)
      info "Hysteria2 必须使用证书 TLS。"
      build_certificate_tls tls || return 1
      ;;
    *) die "${type} 入站没有 sbctl 可管理的 TLS/REALITY 安全层。";;
  esac
  host=$(public_host_for_tag "$tag") || return 1
  tmp=$(temp_file); meta_tmp=$(temp_file)
  jq --arg tag "$tag" --argjson tls "$tls" --arg type "$type" '
    (.inbounds[]|select(.tag==$tag)|.tls)=$tls |
    if $tls.reality.enabled==true then (.inbounds[]|select(.tag==$tag)) |= del(.transport) else . end' "$CONFIG_FILE" >"$tmp"
  build_inbound_meta_candidate "$tag" "$host" "$public" "$tmp" "$meta_tmp"
  if apply_candidate_with_meta "$tmp" "$meta_tmp"; then info "入站 ${tag} 的安全方式已更新。"; else rc=$?; fi
  rm -f "$tmp" "$meta_tmp"
  return "$rc"
}

validate_websocket_path() {
  [[ $1 != *[[:space:]]* ]] || { error "WebSocket 路径不能包含空白字符。"; return 1; }
}

modify_inbound_transport() {
  ensure_dependencies inbound-modify; require_supported_core; ensure_config
  local tag=${1-} type choice path host transport tmp rc=0
  [[ -n $tag ]] || select_inbound tag || return 0
  inbound_exists "$tag" || die "找不到入站：$tag"
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
  if ! protocol_capability "$type" transport; then error "${type} 不支持此传输编辑。"; return 1; fi
  if jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.reality.enabled==true' "$CONFIG_FILE" >/dev/null; then
    error "REALITY 入站仅支持 TCP；请先修改安全方式。"; return 1
  fi
  choose choice "传输方式" "tcp" "ws" || return 1
  transport=null
  if [[ $choice == 2 ]]; then
    prompt_value path "WebSocket 路径" "/" || return 1
    validate_websocket_path "$path" || return 1
    host=$(public_host_for_tag "$tag") || return 1
    transport=$(jq -n --arg path "$path" --arg host "$host" '{type:"ws",path:$path,headers:{Host:$host}}')
  fi
  tmp=$(temp_file)
  jq --arg tag "$tag" --argjson transport "$transport" '(.inbounds[]|select(.tag==$tag)) |= (if $transport==null then del(.transport) else .transport=$transport end)' "$CONFIG_FILE" >"$tmp"
  apply_candidate "$tmp" || rc=$?
  rm -f "$tmp"
  return "$rc"
}

rename_inbound() {
  ensure_dependencies inbound-rename; ensure_config
  local old=${1-} new=${2-} tmp meta_tmp rc=0
  [[ -n $old ]] || select_inbound old || return 0
  inbound_exists "$old" || die "找不到入站：$old"
  if [[ -z $new ]]; then
    while true; do
      prompt_value new "新入站名称" "$old" || return 1
      [[ $new == "$old" ]] && { info "名称未更改。"; return 0; }
      validate_tag "$new" || { warn "标签只能包含字母、数字、点、下划线和横线。"; continue; }
      if inbound_exists "$new" || outbound_exists "$new"; then warn "标签已存在，请重新输入。"; continue; fi
      break
    done
  fi
  validate_tag "$new" || die "标签格式无效。"
  inbound_exists "$new" && die "入站标签已存在：$new"
  outbound_exists "$new" && die "出站标签已存在：$new"
  tmp=$(temp_file); meta_tmp=$(temp_file); init_meta
  jq --arg old "$old" --arg new "$new" '
    (.inbounds[]|select(.tag==$old)|.tag)=$new |
    .route.rules = [(.route.rules // [])[]? |
      if ((.inbound // null)|type)=="array" then
        .inbound |= map(if .==$old then $new else . end)
      elif (.inbound // null)==$old then .inbound=$new
      else . end]' "$CONFIG_FILE" >"$tmp"
  jq --arg old "$old" --arg new "$new" '
    (if .inbounds[$old] then .inbounds[$new]=.inbounds[$old] | del(.inbounds[$old]) else . end) |
    .domainTemplates=(.domainTemplates // {templates:[],bindings:[]}) |
    .domainTemplates.bindings=[.domainTemplates.bindings[]? |
      if .inbound==$old then .inbound=$new else . end] |
    .domainTemplates.managed=[.domainTemplates.managed[]? |
      if .inbound==$old then .inbound=$new else . end]
  ' "$META_FILE" >"$meta_tmp"
  if apply_candidate_with_meta "$tmp" "$meta_tmp"; then
    hy2_hop_sync || { warn "入站已重命名，但端口跳跃规则同步失败，请重试同步。"; rc=1; }
    traffic_after_config_change "$old" "$new" || warn "流量统计记录未能迁移，请在流量信息中刷新。"
    info "入站已重命名：${old} -> ${new}"
  else
    rc=$?
  fi
  rm -f "$tmp" "$meta_tmp"
  return "$rc"
}
