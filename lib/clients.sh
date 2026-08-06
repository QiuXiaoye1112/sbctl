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
  ensure_config
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
  local names=() name
  list_clients "$tag"
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
  field=$(client_label_field "$type")
  while IFS= read -r name; do
    [[ -n $name ]] && names+=("$name")
  done < <(jq -r --arg tag "$tag" --arg field "$field" '.inbounds[]|select(.tag==$tag)|.users[]?|.[$field]' "$CONFIG_FILE")
  ((${#names[@]})) || { warn "该入站还没有用户。"; return 1; }
  if ((${#names[@]} == 1)); then
    printf -v "$__var" '%s' "${names[0]}"
    return 0
  fi
  local choice
  choose choice "选择用户" "${names[@]}"
  printf -v "$__var" '%s' "${names[$((choice-1))]}"
}

delete_client() {
  ensure_dependencies client-delete; ensure_config
  local tag=${1-} name=${2-} type field tmp
  [[ -n $tag ]] || select_inbound tag || return 0
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
  field=$(client_label_field "$type")
  if [[ -z $name ]]; then
    select_client name "$tag" || return 0
  fi
  client_exists "$tag" "$name" || die "找不到用户：${name}"
  confirm "删除用户 ${name}？" N || return
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
  [[ -n $name ]] || { select_client name "$tag" || return 0; }
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

print_share() {
  ensure_config
  local tag=${1-} filter=${2-} type host h port name value sni public sid security tls_enabled obfs obfs_password
  [[ -n $tag ]] || select_inbound tag || return 0
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
  host=$(public_host_for_tag "$tag") || warn "无法确定入站 ${tag} 的客户端连接地址。"; h=$(uri_host "$host")
  port=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen_port' "$CONFIG_FILE")
  heading "${tag} 分享信息"
  case $type in
    vless)
      sni=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.server_name // empty' "$CONFIG_FILE")
      tls_enabled=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.enabled // false' "$CONFIG_FILE")
      if jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.reality.enabled==true' "$CONFIG_FILE" >/dev/null; then
        security=reality; public=$(reality_public_key "$tag") || warn "REALITY 公钥元数据缺失或与当前私钥不匹配。"; sid=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.reality.short_id[0]' "$CONFIG_FILE")
      elif [[ $tls_enabled == true ]]; then security=tls
      else warn "VLESS 入站未启用 TLS/REALITY，sbctl 不生成不受支持的分享链接。"; return 0
      fi
      while IFS=$'\t' read -r name value; do
        [[ -z $filter || $name == "$filter" ]] || continue
        if [[ $security == reality ]]; then
          printf '用户: %s\nvless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s\n\n' "$name" "$value" "$h" "$port" "$(url_encode "$sni")" "$(url_encode "$public")" "$(url_encode "$sid")" "$(url_encode "${tag}-${name}")"
        else
          printf '用户: %s\nvless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=tcp#%s\n\n' "$name" "$value" "$h" "$port" "$(url_encode "$sni")" "$(url_encode "${tag}-${name}")"
        fi
      done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[]|[.name,.uuid]|@tsv' "$CONFIG_FILE")
      ;;
    trojan)
      sni=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.server_name // empty' "$CONFIG_FILE")
      tls_enabled=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.enabled // false' "$CONFIG_FILE")
      if jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.reality.enabled==true' "$CONFIG_FILE" >/dev/null; then
        security=reality; public=$(reality_public_key "$tag") || warn "REALITY 公钥元数据缺失或与当前私钥不匹配。"; sid=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.reality.short_id[0]' "$CONFIG_FILE")
      elif [[ $tls_enabled == true ]]; then security=tls
      else warn "Trojan 入站未启用 TLS/REALITY，sbctl 不生成不受支持的分享链接。"; return 0
      fi
      while IFS=$'\t' read -r name value; do
        [[ -z $filter || $name == "$filter" ]] || continue
        if [[ $security == reality ]]; then
          printf '用户: %s\ntrojan://%s@%s:%s?security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n\n' "$name" "$(url_encode "$value")" "$h" "$port" "$(url_encode "$sni")" "$(url_encode "$public")" "$(url_encode "$sid")" "$(url_encode "${tag}-${name}")"
        else
          printf '用户: %s\ntrojan://%s@%s:%s?security=tls&sni=%s&type=tcp#%s\n\n' "$name" "$(url_encode "$value")" "$h" "$port" "$(url_encode "$sni")" "$(url_encode "${tag}-${name}")"
        fi
      done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[]|[.name,.password]|@tsv' "$CONFIG_FILE")
      ;;
    anytls)
      while IFS= read -r name; do
        [[ -z $filter || $name == "$filter" ]] || continue
        printf '用户: %s\n客户端 outbound JSON:\n' "$name"
        client_json_for_anytls "$tag" "$name"
        printf '\n\n'
      done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[].name' "$CONFIG_FILE")
      ;;
    hysteria2)
      jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.enabled==true' "$CONFIG_FILE" >/dev/null || { warn "Hysteria2 必须启用 TLS。"; return 0; }
      sni=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.server_name' "$CONFIG_FILE")
      obfs=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.obfs.type // empty' "$CONFIG_FILE")
      obfs_password=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.obfs.password // empty' "$CONFIG_FILE")
      while IFS=$'\t' read -r name value; do
        [[ -z $filter || $name == "$filter" ]] || continue
        printf '用户: %s\nhysteria2://%s@%s:%s?sni=%s' "$name" "$(url_encode "$value")" "$h" "$port" "$(url_encode "$sni")"
        [[ -z $obfs ]] || printf '&obfs=%s&obfs-password=%s' "$(url_encode "$obfs")" "$(url_encode "$obfs_password")"
        printf '#%s\n\n' "$(url_encode "${tag}-${name}")"
      done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[]|[.name,.password]|@tsv' "$CONFIG_FILE")
      ;;
    socks|http|mixed)
      if [[ $(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.users//[])|length' "$CONFIG_FILE") == 0 ]]; then
        printf '%s://%s:%s  无认证\n' "$type" "$h" "$port"
      else
        jq -r --arg tag "$tag" --arg host "$host" --arg port "$port" '.inbounds[]|select(.tag==$tag)|.users[]|"\(.username)\t\(.password)"' "$CONFIG_FILE" | while IFS=$'\t' read -r name value; do printf '%s://%s:%s  用户=%s 密码=%s\n' "$type" "$h" "$port" "$name" "$value"; done
      fi
      ;;
  esac
}
