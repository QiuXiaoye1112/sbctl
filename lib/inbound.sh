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

managed_certificate_count() {
  local c n=0
  for c in "$CERT_DIR"/*.crt; do [[ -r $c && -r ${c%.crt}.key ]] && ((n+=1)); done
  printf '%s' "$n"
}
select_managed_certificate() {
  local __var=$1 cert answer item
  local items=()
  for cert in "$CERT_DIR"/*.crt; do
    [[ -r $cert && -r ${cert%.crt}.key ]] || continue
    items+=("$(basename "$cert" .crt)")
  done
  ((${#items[@]})) || { warn "没有托管证书，请先运行 sbctl cert import/issue。"; return 1; }
  if ((${#items[@]} == 1)); then item=${items[0]}; else choose answer "选择证书" "${items[@]}"; item=${items[$((answer-1))]}; fi
  printf -v "$__var" '%s' "$item"
}

validate_certificate_pair() {
  local cert=$1 key=$2 cp kp
  [[ -r $cert && -r $key ]] || return 1
  openssl x509 -in "$cert" -noout >/dev/null 2>&1 || return 1
  openssl pkey -in "$key" -noout >/dev/null 2>&1 || return 1
  cp=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256)
  kp=$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | openssl sha256)
  [[ -n $cp && $cp == "$kp" ]]
}

build_certificate_tls() {
  local __json=$1 identifier sni
  select_managed_certificate identifier || return 1
  prompt_value sni "TLS serverName/SNI" "$identifier"
  validate_host "$sni" || die "SNI 必须是域名或 IP。"
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
  prompt_value target "REALITY 握手目标" "www.microsoft.com"
  validate_domain "$target" || die "REALITY 握手目标必须是域名。"
  prompt_value port "REALITY 握手端口" 443
  validate_port "$port" || die "端口无效。"
  prompt_value sni "REALITY serverName/SNI" "$target"
  validate_domain "$sni" || die "SNI 必须是域名。"
  generate_reality_keys __generated_private __generated_public
  short_id=$(random_hex 4)
  printf -v "$__json" '%s' "$(jq -n --arg sni "$sni" --arg server "$target" --argjson port "$port" --arg private "$__generated_private" --arg sid "$short_id" '{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$server,server_port:$port},private_key:$private,short_id:[$sid]}}')"
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
  local __json=$1 __host=$2 __public=$3 choice type tag listen port client_host tls="" reality_public="" name password uuid flow="" obfs_choice obfs_password up down
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
}

add_inbound() {
  ensure_dependencies inbound-add; require_supported_core; ensure_config
  local inbound host public tag tmp
  build_inbound inbound host public
  tag=$(jq -r '.tag' <<<"$inbound")
  tmp=$(temp_file)
  jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then
    meta_set_inbound "$tag" "$host" "$public"
    heading "入站已创建"
    show_inbound "$tag"
    print_share "$tag" "" || true
  fi
  rm -f "$tmp"
}

list_inbounds() {
  ensure_config
  local count tag type port security users
  local tag_width=24 type_width=14 port_width=8 security_width=12 users_width=6
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
  local tag=${1-} yes=${2:-0} tmp
  [[ -n $tag ]] || select_inbound tag || return
  inbound_exists "$tag" || die "找不到入站：$tag"
  [[ $yes == 1 ]] || confirm "删除入站 ${tag}？" N || return
  tmp=$(temp_file)
  jq --arg tag "$tag" '.inbounds |= map(select(.tag!=$tag))' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then meta_delete_inbound "$tag"; info "已删除入站 ${tag}。"; fi
  rm -f "$tmp"
}

modify_inbound_basic() {
  ensure_dependencies inbound-modify; ensure_config
  local tag=${1-} listen port host tmp
  [[ -n $tag ]] || select_inbound tag || return
  inbound_exists "$tag" || die "找不到入站：$tag"
  prompt_value listen "监听地址" "$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen // "0.0.0.0"' "$CONFIG_FILE")"
  prompt_port port "$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen_port' "$CONFIG_FILE")" "$tag"
  prompt_public_host host "$(public_host_for_tag "$tag")"
  tmp=$(temp_file)
  jq --arg tag "$tag" --arg listen "$listen" --argjson port "$port" '(.inbounds[]|select(.tag==$tag)) |= (.listen=$listen | .listen_port=$port)' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then
    meta_set_inbound "$tag" "$host" "$(jq -r --arg tag "$tag" '.inbounds[$tag].realityPublicKey // empty' "$META_FILE")"
  fi
  rm -f "$tmp"
}
