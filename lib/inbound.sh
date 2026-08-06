# shellcheck shell=bash
# sbctl inbound — canonical inbound CRUD with transactional meta updates.
# Optimized: single jq call per display page, no function overrides.

inbound_exists() { jq -e --arg tag "$1" '.inbounds[]?|select(.tag==$tag)' "$CONFIG_FILE" >/dev/null; }
port_in_config() { jq -e --argjson port "$1" --arg except "${2-}" '.inbounds[]?|select(.listen_port==$port and .tag!=$except)' "$CONFIG_FILE" >/dev/null; }
port_in_use_os() {
  local port=$1
  if command_exists ss; then ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)${port}$"
  elif command_exists netstat; then netstat -lntu 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"
  else return 1; fi
}

prompt_tag() {
  local __var=$1 default=$2 value
  while true; do
    prompt_value value "入站标签" "$default"
    validate_tag "$value" || { warn "标签只能包含字母、数字、点、下划线和横线。"; continue; }
    inbound_exists "$value" && { warn "标签已存在。"; continue; }
    printf -v "$__var" '%s' "$value"; return
  done
}
prompt_port() {
  local __var=$1 default=${2:-443} except=${3-} value
  while true; do
    prompt_value value "监听端口" "$default"
    validate_port "$value" || { warn "端口必须为 1-65535。"; continue; }
    port_in_config "$value" "$except" && { warn "该端口已被其他入站使用。"; continue; }
    if port_in_use_os "$value" && [[ -z $except ]]; then confirm "系统检测到端口 ${value} 已占用，仍继续？" N || continue; fi
    printf -v "$__var" '%s' "$value"; return
  done
}

managed_certificate_count() { init_meta; jq -r '.certificates | length' "$META_FILE" 2>/dev/null || printf '0'; }

select_managed_certificate() {
  local __var=$1 always_choose=${2:-0} id answer
  local ids=()
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    [[ -r "$CERT_DIR/${id}.crt" && -r "$CERT_DIR/${id}.key" ]] && ids+=("$id")
  done < <(meta_cert_list)
  ((${#ids[@]} > 0)) || { warn "没有可用的托管证书，请先运行 sbctl cert import/issue。"; return 1; }
  if ((${#ids[@]} == 1)) && [[ $always_choose != 1 ]]; then
    printf -v "$__var" '%s' "${ids[0]}"; return 0
  fi
  choose answer "选择证书" "${ids[@]}" || return 1
  printf -v "$__var" '%s' "${ids[$((answer-1))]}"
}

validate_certificate_pair() {
  local cert=$1 key=$2 cert_pub key_pub
  [[ -r $cert && -r $key ]] || return 1
  openssl x509 -in "$cert" -noout >/dev/null 2>&1 || return 1
  openssl x509 -in "$cert" -checkend 0 -noout >/dev/null 2>&1 || return 1
  openssl pkey -in "$key" -noout >/dev/null 2>&1 || return 1
  cert_pub=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256)
  key_pub=$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | openssl sha256)
  [[ -n $cert_pub && $cert_pub == "$key_pub" ]]
}

build_certificate_tls() {
  local __json=$1 identifier sni
  select_managed_certificate identifier || return 1
  prompt_certificate_server_name sni "$CERT_DIR/${identifier}.crt" || return 1
  printf -v "$__json" '%s' "$(jq -n --arg sni "$sni" --arg cert "$CERT_DIR/${identifier}.crt" --arg key "$CERT_DIR/${identifier}.key" '{enabled:true,server_name:$sni,certificate_path:$cert,key_path:$key,min_version:"1.2"}')"
}

generate_reality_keys() {
  local __private=$1 __public=$2 output __key_private __key_public
  require_sing_box
  output=$("$SING_BOX_BIN" generate reality-keypair)
  __key_private=$(awk '/PrivateKey/ {print $NF; exit}' <<<"$output" | tr -d '"')
  __key_public=$(awk '/PublicKey/ {print $NF; exit}' <<<"$output" | tr -d '"')
  [[ -n $__key_private && -n $__key_public ]] || { error "$output"; die "无法解析 REALITY 密钥。"; }
  printf -v "$__private" '%s' "$__key_private"
  printf -v "$__public" '%s' "$__key_public"
}

build_reality_tls() {
  local __json=$1 __public=$2 target sni port __generated_private __generated_public short_id

  while true; do
    prompt_value target "REALITY 目标" "www.microsoft.com:443" || return 1
    validate_reality_target "$target" && break
    warn "目标格式应为 域名:端口，请重新输入。"
  done

  sni=${target%:*}
  port=${target##*:}
  while true; do
    prompt_value sni "REALITY serverName/SNI" "$sni" || return 1
    validate_domain "$sni" && break
    warn "SNI 必须是有效域名，请重新输入。"
  done

  generate_reality_keys __generated_private __generated_public
  short_id=$(random_hex 4)
  printf -v "$__json" '%s' "$(jq -n --arg sni "$sni" --arg server "${target%:*}" --argjson port "$port" --arg private "$__generated_private" --arg sid "$short_id" '{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$server,server_port:$port},private_key:$private,short_id:[$sid]}}')"
  printf -v "$__public" '%s' "$__generated_public"
}

reality_public_key() {
  local tag=$1 private cached expected_sha current_sha
  private=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.reality.private_key // empty' "$CONFIG_FILE")
  [[ -n $private ]] || return 1
  cached=$(jq -r --arg tag "$tag" '.inbounds[$tag].realityPublicKey // empty' "$META_FILE" 2>/dev/null || true)
  expected_sha=$(jq -r --arg tag "$tag" '.inbounds[$tag].realityPrivateSHA256 // empty' "$META_FILE" 2>/dev/null || true)
  [[ -n $cached && -n $expected_sha ]] || return 1
  current_sha=$(printf '%s' "$private" | openssl dgst -sha256 -r | awk '{print $1}')
  [[ $current_sha == "$expected_sha" ]] || return 1
  printf '%s' "$cached"
}

build_inbound() {
  local __json=$1 __host=$2 __public=$3 __hop=${4-} choice type tag listen port client_host tls="" reality_public="" name password uuid flow="" obfs_choice obfs_password up down selected_hop_range=""
  choose choice "选择入站协议" "AnyTLS" "VLESS" "Hysteria2" "Trojan" "SOCKS5" "HTTP" "Mixed(SOCKS+HTTP)"
  case $choice in 1) type=anytls;; 2) type=vless;; 3) type=hysteria2;; 4) type=trojan;; 5) type=socks;; 6) type=http;; 7) type=mixed;; esac
  prompt_tag tag "${type}-$(random_hex 2)"
  prompt_value listen "监听地址" "0.0.0.0"
  prompt_port port 443
  prompt_public_host client_host

  case $type in
    anytls|vless|trojan)
      choose choice "选择 TLS 安全层" "REALITY" "证书 TLS"
      if [[ $choice == 1 ]]; then build_reality_tls tls reality_public; else build_certificate_tls tls; fi
      ;;
    hysteria2)
      build_certificate_tls tls
      ;;
  esac

  case $type in
    anytls)
      prompt_value name "用户名称" "user-$(random_hex 2)"
      prompt_secret password "AnyTLS 密码" "$(random_password)"
      printf -v "$__json" '%s' "$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg name "$name" --arg password "$password" --argjson tls "$tls" '{type:"anytls",tag:$tag,listen:$listen,listen_port:$port,users:[{name:$name,password:$password}],tls:$tls}')"
      ;;
    vless)
      prompt_value name "用户名称" "user-$(random_hex 2)"
      uuid=$(generate_uuid)
      [[ $(jq -r '.reality.enabled // false' <<<"$tls") == true ]] && flow=xtls-rprx-vision || flow=""
      printf -v "$__json" '%s' "$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg name "$name" --arg uuid "$uuid" --arg flow "$flow" --argjson tls "$tls" '{type:"vless",tag:$tag,listen:$listen,listen_port:$port,users:[{name:$name,uuid:$uuid,flow:$flow}],tls:$tls}')"
      ;;
    hysteria2)
      prompt_value name "用户名称" "user-$(random_hex 2)"
      prompt_secret password "Hysteria2 密码" "$(random_password)"
      prompt_optional_positive_int up "上行限制 Mbps（留空=不限）"
      prompt_optional_positive_int down "下行限制 Mbps（留空=不限）"
      choose obfs_choice "QUIC 混淆" "关闭" "Salamander"
      if [[ $obfs_choice == 2 ]]; then prompt_secret obfs_password "混淆密码" "$(random_password)"; fi
      printf -v "$__json" '%s' "$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg name "$name" --arg password "$password" --arg up "$up" --arg down "$down" --arg obfs "$obfs_password" --argjson tls "$tls" '
        {type:"hysteria2",tag:$tag,listen:$listen,listen_port:$port,users:[{name:$name,password:$password}],tls:$tls} |
        if $up!="" then .up_mbps=($up|tonumber) else . end |
        if $down!="" then .down_mbps=($down|tonumber) else . end |
        if $obfs!="" then .obfs={type:"salamander",password:$obfs} else . end')"
      ;;
    trojan)
      prompt_value name "用户名称" "user-$(random_hex 2)"
      prompt_secret password "Trojan 密码" "$(random_password)"
      printf -v "$__json" '%s' "$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg name "$name" --arg password "$password" --argjson tls "$tls" '{type:"trojan",tag:$tag,listen:$listen,listen_port:$port,users:[{name:$name,password:$password}],tls:$tls}')"
      ;;
    socks|http|mixed)
      prompt_optional name "用户名（留空=无认证）"
      if [[ -n $name ]]; then prompt_secret password "密码" "$(random_password)"; fi
      if [[ -n $name ]]; then
        printf -v "$__json" '%s' "$(jq -n --arg type "$type" --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg user "$name" --arg pass "$password" '{type:$type,tag:$tag,listen:$listen,listen_port:$port,users:[{username:$user,password:$pass}]}')"
      else
        [[ $listen == 127.0.0.1 || $listen == ::1 ]] || warn "公网无认证代理风险很高。"
        printf -v "$__json" '%s' "$(jq -n --arg type "$type" --arg tag "$tag" --arg listen "$listen" --argjson port "$port" '{type:$type,tag:$tag,listen:$listen,listen_port:$port,users:[]}')"
      fi
      ;;
  esac
  printf -v "$__host" '%s' "$client_host"
  printf -v "$__public" '%s' "$reality_public"
  [[ -z $__hop ]] || printf -v "$__hop" '%s' "$selected_hop_range"
}

# ---- canonical CRUD (merged from state_guard.sh and management.sh) ----

add_inbound() {
  ensure_dependencies inbound-add; require_supported_core; ensure_config
  local inbound host public tag tmp meta_tmp rc=0 type
  build_inbound inbound host public
  tag=$(jq -r '.tag' <<<"$inbound")
  type=$(jq -r '.type' <<<"$inbound")
  tmp=$(temp_file); meta_tmp=$(temp_file)
  jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" >"$tmp"
  build_inbound_meta_candidate "$tag" "$host" "$public" "$tmp" "$meta_tmp"
  if apply_candidate_with_meta "$tmp" "$meta_tmp"; then
    # Hysteria2 port hopping integration (from hy2_hop.sh)
    if [[ $type == hysteria2 && -t 0 ]]; then
      if ! hy2_hop_configure "$tag" 1; then warn "端口跳跃配置未完成；Hysteria2 入站本身已创建。"; fi
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

# Single-jq list_inbounds — one jq call for the entire table
list_inbounds() {
  ensure_config
  local count tag_width=24 type_width=14 port_width=8 security_width=12 users_width=6
  count=$(jq '.inbounds|length' "$CONFIG_FILE")
  ((count)) || { info "还没有入站。"; return 0; }

  print_table_cell_clipped "标签" "$tag_width"; printf '| '
  print_table_cell_clipped "协议" "$type_width"; printf '| '
  print_table_cell "端口" "$port_width"; printf '| '
  print_table_cell_clipped "安全" "$security_width"; printf '| '
  printf '用户\n'

  jq -r '.inbounds[] | [.tag,.type,(.listen_port|tostring),(if .tls.reality.enabled==true then "reality" elif .tls.enabled==true then "tls" else "none" end),((.users//[])|length|tostring)] | @tsv' "$CONFIG_FILE" |
    while IFS=$'\t' read -r tag type port security users; do
      print_table_cell_clipped "$tag" "$tag_width"; printf '| '
      print_table_cell_clipped "$type" "$type_width"; printf '| '
      print_table_cell "$port" "$port_width"; printf '| '
      print_table_cell_clipped "$security" "$security_width"; printf '| '
      printf '%s\n' "$users"
    done
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
  if ((${#tags[@]} == 1)); then __selected=${tags[0]}; else choose __answer "选择入站" "${tags[@]}"; __selected=${tags[$((__answer-1))]}; fi
  printf -v "$__var" '%s' "$__selected"
}

delete_inbound() {
  ensure_dependencies inbound-delete; ensure_config
  local tag=${1-} yes=${2:-0} tmp meta_tmp rc=0
  [[ -n $tag ]] || select_inbound tag || return 0
  inbound_exists "$tag" || die "找不到入站：$tag"
  [[ $yes == 1 ]] || confirm "删除入站 ${tag}？" N || return
  tmp=$(temp_file); meta_tmp=$(temp_file); init_meta
  jq --arg tag "$tag" '
    .inbounds |= map(select(.tag!=$tag)) |
    .route.rules = [(.route.rules // [])[]? |
      if ((.inbound // null)|type)=="array" and ((.inbound // [])|index($tag))!=null then
        .inbound |= map(select(.!=$tag)) | select((.inbound|length)>0)
      elif (.inbound // null)==$tag then empty
      else . end]' "$CONFIG_FILE" >"$tmp"
  jq --arg tag "$tag" 'del(.inbounds[$tag])' "$META_FILE" >"$meta_tmp"
  if apply_candidate_with_meta "$tmp" "$meta_tmp"; then
    hy2_hop_sync
    info "已删除入站 ${tag}。"
  else
    rc=$?
  fi
  rm -f "$tmp" "$meta_tmp"
  return "$rc"
}

modify_inbound_basic() {
  ensure_dependencies inbound-modify; ensure_config
  local tag=${1-} listen port host public tmp meta_tmp rc=0
  [[ -n $tag ]] || select_inbound tag || return 0
  inbound_exists "$tag" || die "找不到入站：$tag"
  prompt_value listen "监听地址" "$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen // "0.0.0.0"' "$CONFIG_FILE")"
  prompt_port port "$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen_port' "$CONFIG_FILE")" "$tag"
  prompt_public_host host "$(public_host_for_tag "$tag")"
  public=$(jq -r --arg tag "$tag" '.inbounds[$tag].realityPublicKey // empty' "$META_FILE" 2>/dev/null || true)
  tmp=$(temp_file); meta_tmp=$(temp_file)
  jq --arg tag "$tag" --arg listen "$listen" --argjson port "$port" '(.inbounds[]|select(.tag==$tag)) |= (.listen=$listen | .listen_port=$port)' "$CONFIG_FILE" >"$tmp"
  build_inbound_meta_candidate "$tag" "$host" "$public" "$tmp" "$meta_tmp"
  if apply_candidate_with_meta "$tmp" "$meta_tmp"; then
    hy2_hop_sync
  else
    rc=$?
  fi
  rm -f "$tmp" "$meta_tmp"
  return "$rc"
}

modify_inbound_security() {
  ensure_dependencies inbound-security; require_supported_core; ensure_config
  local tag=${1-} type choice tls="" public="" tmp meta_tmp host rc=0
  [[ -n $tag ]] || select_inbound tag || return 0
  inbound_exists "$tag" || die "找不到入站：$tag"
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
  case $type in
    anytls|vless|trojan)
      choose choice "选择 TLS 安全层" "REALITY" "证书 TLS"
      if [[ $choice == 1 ]]; then build_reality_tls tls public; else build_certificate_tls tls; fi
      ;;
    hysteria2)
      info "Hysteria2 必须使用证书 TLS。"
      build_certificate_tls tls
      ;;
    *) die "${type} 入站没有 sbctl 可管理的 TLS/REALITY 安全层。";;
  esac
  host=$(public_host_for_tag "$tag" || true)
  [[ -n $host ]] || prompt_public_host host
  tmp=$(temp_file); meta_tmp=$(temp_file)
  jq --arg tag "$tag" --argjson tls "$tls" --arg type "$type" '
    (.inbounds[]|select(.tag==$tag)|.tls)=$tls |
    if $type=="vless" then
      (.inbounds[]|select(.tag==$tag)|.users) |= map(.flow=(if $tls.reality.enabled==true then "xtls-rprx-vision" else "" end))
    else . end' "$CONFIG_FILE" >"$tmp"
  build_inbound_meta_candidate "$tag" "$host" "$public" "$tmp" "$meta_tmp"
  if apply_candidate_with_meta "$tmp" "$meta_tmp"; then info "入站 ${tag} 的安全方式已更新。"; else rc=$?; fi
  rm -f "$tmp" "$meta_tmp"
  return "$rc"
}

rename_inbound() {
  ensure_dependencies inbound-rename; ensure_config
  local old=${1-} new=${2-} tmp meta_tmp rc=0
  [[ -n $old ]] || select_inbound old || return 0
  inbound_exists "$old" || die "找不到入站：$old"
  if [[ -z $new ]]; then
    while true; do
      prompt_value new "新入站名称" "$old"
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
  jq --arg old "$old" --arg new "$new" 'if .inbounds[$old] then .inbounds[$new]=.inbounds[$old] | del(.inbounds[$old]) else . end' "$META_FILE" >"$meta_tmp"
  if apply_candidate_with_meta "$tmp" "$meta_tmp"; then
    hy2_hop_sync
    info "入站已重命名：${old} -> ${new}"
  else
    rc=$?
  fi
  rm -f "$tmp" "$meta_tmp"
  return "$rc"
}
