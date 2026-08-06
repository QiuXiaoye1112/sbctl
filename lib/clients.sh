client_label_field() {
  case $1 in socks|http|mixed) printf username;; *) printf name;; esac
}

client_exists() {
  local tag=$1 name=$2 type field
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
  field=$(client_label_field "$type")
  jq -e --arg tag "$tag" --arg name "$name" --arg field "$field" '.inbounds[]|select(.tag==$tag)|.users[]?|select(.[$field]==$name)' "$CONFIG_FILE" >/dev/null
}

add_client() {
  ensure_dependencies client-add; ensure_config
  local tag=${1-} type name password uuid flow user tmp
  [[ -n $tag ]] || select_inbound tag '^(anytls|vless|hysteria2|trojan|socks|http|mixed)$' || return 0
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
  while true; do
    prompt_value name "用户名称" "user-$(random_hex 2)"
    client_exists "$tag" "$name" && { warn "用户名称已存在。"; continue; }
    break
  done
  case $type in
    vless)
      uuid=$(generate_uuid)
      flow=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[0].flow // empty' "$CONFIG_FILE")
      user=$(jq -n --arg name "$name" --arg uuid "$uuid" --arg flow "$flow" '{name:$name,uuid:$uuid,flow:$flow}') ;;
    anytls|hysteria2|trojan)
      prompt_secret password "密码" "$(random_password)"
      user=$(jq -n --arg name "$name" --arg password "$password" '{name:$name,password:$password}') ;;
    socks|http|mixed)
      prompt_secret password "密码" "$(random_password)"
      user=$(jq -n --arg username "$name" --arg password "$password" '{username:$username,password:$password}') ;;
    *) warn "该协议不支持用户管理。"; return 0;;
  esac
  tmp=$(temp_file)
  jq --arg tag "$tag" --argjson user "$user" '(.inbounds[]|select(.tag==$tag)|.users) += [$user]' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then info "用户 ${name} 已添加。"; print_share "$tag" "$name" || true; fi
  rm -f "$tmp"
}

list_clients() {
  # Pure display — does NOT call ensure_config.
  [[ -f $CONFIG_FILE ]] || { info "配置不存在。"; return 1; }
  local tag=${1-} type i=0 name cred
  [[ -n $tag ]] || select_inbound tag || return 0
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
  heading "${tag} 用户"
  case $type in
    vless)
      while IFS=$'\t' read -r name cred; do
        ((i+=1))
        printf ' %-2d) %-20s %s\n' "$i" "$name" "$cred"
      done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[]?|[.name,.uuid]|@tsv' "$CONFIG_FILE")
      ;;
    anytls|hysteria2|trojan)
      while IFS=$'\t' read -r name cred; do
        ((i+=1))
        printf ' %-2d) %-20s %s\n' "$i" "$name" "$cred"
      done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[]?|[.name,.password]|@tsv' "$CONFIG_FILE")
      ;;
    socks|http|mixed)
      while IFS=$'\t' read -r name cred; do
        ((i+=1))
        printf ' %-2d) %-20s %s\n' "$i" "$name" "$cred"
      done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[]?|[.username,.password]|@tsv' "$CONFIG_FILE")
      ;;
  esac
  (($i)) || info "还没有用户。"
}

select_client() {
  local __var=$1 tag=$2 type field
  local names=() _n
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
  field=$(client_label_field "$type")
  while IFS= read -r _n; do
    [[ -n $_n ]] && names+=("$_n")
  done < <(jq -r --arg tag "$tag" --arg field "$field" '.inbounds[]|select(.tag==$tag)|.users[]?|.[$field]' "$CONFIG_FILE")
  ((${#names[@]})) || { warn "该入站还没有用户。"; return 1; }
  if ((${#names[@]} == 1)); then
    printf -v "$__var" '%s' "${names[0]}"
    return 0
  fi
  local choice
  choose choice "选择用户" "${names[@]}" || return 1
  printf -v "$__var" '%s' "${names[$((choice-1))]}"
}

delete_client() {
  ensure_dependencies client-delete; ensure_config
  local tag=${1-} name=${2-} type field tmp
  [[ -n $tag ]] || select_inbound tag || return 0
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
  field=$(client_label_field "$type")
  if [[ -z $name ]]; then
    list_clients "$tag"
    select_client name "$tag" || return 0
  fi
  client_exists "$tag" "$name" || die "找不到用户：${name}"
  confirm "删除用户 ${name}？" N || return 0
  tmp=$(temp_file)
  jq --arg tag "$tag" --arg name "$name" --arg field "$field" '(.inbounds[]|select(.tag==$tag)|.users) |= map(select(.[$field]!=$name))' "$CONFIG_FILE" >"$tmp"
  apply_candidate "$tmp"; rm -f "$tmp"
}

rotate_client_credential() {
  ensure_dependencies client-rotate; ensure_config
  local tag=${1-} name=${2-} type field value tmp
  [[ -n $tag ]] || select_inbound tag || return 0
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
  field=$(client_label_field "$type")
  [[ -n $name ]] || { list_clients "$tag"; select_client name "$tag" || return 0; }
  client_exists "$tag" "$name" || die "找不到用户：${name}"
  tmp=$(temp_file)
  if [[ $type == vless ]]; then
    value=$(generate_uuid)
    jq --arg tag "$tag" --arg name "$name" --arg field "$field" --arg value "$value" '(.inbounds[]|select(.tag==$tag)|.users[]|select(.[$field]==$name)|.uuid)=$value' "$CONFIG_FILE" >"$tmp"
  else
    value=$(random_password)
    jq --arg tag "$tag" --arg name "$name" --arg field "$field" --arg value "$value" '(.inbounds[]|select(.tag==$tag)|.users[]|select(.[$field]==$name)|.password)=$value' "$CONFIG_FILE" >"$tmp"
  fi
  if apply_candidate "$tmp"; then info "新凭据：${value}"; fi
  rm -f "$tmp"
}

client_json_for_anytls() {
  local tag=$1 name=$2 host port password sni public sid
  host=$(public_host_for_tag "$tag") || warn "无法确定入站 ${tag} 的客户端连接地址。"; port=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen_port' "$CONFIG_FILE")
  password=$(jq -r --arg tag "$tag" --arg name "$name" '.inbounds[]|select(.tag==$tag)|.users[]|select(.name==$name)|.password' "$CONFIG_FILE")
  sni=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.server_name // empty' "$CONFIG_FILE")
  jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.enabled==true' "$CONFIG_FILE" >/dev/null || { warn "AnyTLS 入站未启用 TLS，sbctl 不生成不受支持的客户端配置。"; return 0; }
  if jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.reality.enabled==true' "$CONFIG_FILE" >/dev/null; then
    public=$(reality_public_key "$tag") || warn "REALITY 公钥元数据缺失或与当前私钥不匹配；请重新创建该 REALITY 入站。"
    sid=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.reality.short_id[0]' "$CONFIG_FILE")
    jq -n --arg host "$host" --argjson port "$port" --arg password "$password" --arg sni "$sni" --arg public "$public" --arg sid "$sid" '{type:"anytls",tag:"proxy",server:$host,server_port:$port,password:$password,tls:{enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:"chrome"},reality:{enabled:true,public_key:$public,short_id:$sid}}}'
  else
    jq -n --arg host "$host" --argjson port "$port" --arg password "$password" --arg sni "$sni" '{type:"anytls",tag:"proxy",server:$host,server_port:$port,password:$password,tls:{enabled:true,server_name:$sni}}'
  fi
}

# Canonical print_share lives in share.sh
