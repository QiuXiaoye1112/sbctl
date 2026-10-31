# Share output aligned with xrayctl's interaction style.

share_separator() {
  printf '%s\n' '------------------------------------------------------------------------'
}

print_share_entry() {
  local label=$1 field=$2 value=$3
  share_separator
  printf '用户: %s\n%s: %s\n' "$label" "$field" "$value"
}

print_share() {
  # Does NOT call ensure_config — caller validates config once at entry.
  [[ -f $CONFIG_FILE ]] || { warn "配置不存在。"; return 1; }
  local tag=${1-} filter=${2-} type host uri_host port name value sni public sid security tls_enabled obfs obfs_password link json
  [[ -n $tag ]] || select_inbound tag || return 0
  inbound_exists "$tag" || die "找不到入站：$tag"
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
  protocol_capability "$type" share || { warn "该入站协议不提供 sbctl 分享信息：${type}"; return 0; }
  host=$(public_host_for_tag "$tag") || return 1
  uri_host=$(uri_host "$host")
  port=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen_port' "$CONFIG_FILE")
  heading "${tag} 分享信息"

  case $type in
    hysteria2)
      jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.enabled==true' "$CONFIG_FILE" >/dev/null || { warn "Hysteria2 必须启用 TLS。"; return 0; }
      sni=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.server_name' "$CONFIG_FILE")
      obfs=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.obfs.type // empty' "$CONFIG_FILE")
      obfs_password=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.obfs.password // empty' "$CONFIG_FILE")
      share_port=$(hy2_hop_client_port_spec "$tag" "$port")
      while IFS=$'\t' read -r name value; do
        [[ -z $filter || $name == "$filter" ]] || continue
        link="hysteria2://$(url_encode "$value")@${uri_host}:${share_port}?sni=$(url_encode "$sni")"
        [[ -z $obfs ]] || link+="&obfs=$(url_encode "$obfs")&obfs-password=$(url_encode "$obfs_password")"
        link+="#$(url_encode "${tag}-${name}")"
        print_share_entry "$name" "链接" "$link"
      done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[]|[.name,.password]|@tsv' "$CONFIG_FILE")
      ;;

    anytls)
      sni=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.server_name // empty' "$CONFIG_FILE")
      tls_enabled=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.enabled // false' "$CONFIG_FILE")
      [[ $tls_enabled == true ]] || { warn "AnyTLS 入站未启用 TLS，无法生成分享信息。"; return 0; }
      if jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.reality.enabled==true' "$CONFIG_FILE" >/dev/null; then
        while IFS= read -r name; do
          [[ -z $filter || $name == "$filter" ]] || continue
          json=$(client_json_for_anytls "$tag" "$name") || return 1
          print_share_entry "$name" "客户端 outbound JSON" "$json"
        done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[].name' "$CONFIG_FILE")
      else
        while IFS=$'\t' read -r name value; do
          [[ -z $filter || $name == "$filter" ]] || continue
          link="anytls://$(url_encode "$value")@${uri_host}:${port}/?sni=$(url_encode "$sni")#$(url_encode "${tag}-${name}")"
          print_share_entry "$name" "链接" "$link"
        done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[]|[.name,.password]|@tsv' "$CONFIG_FILE")
      fi
      ;;

    socks|http)
      local scheme=$type
      [[ $type != socks ]] || scheme=socks5
      if [[ $(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.users//[])|length' "$CONFIG_FILE") == 0 ]]; then
        link="${scheme}://${uri_host}:${port}#$(url_encode "$tag")"
        print_share_entry "无认证" "链接" "$link"
      else
        while IFS=$'\t' read -r name value; do
          [[ -z $filter || $name == "$filter" ]] || continue
          link="${scheme}://$(url_encode "$name"):$(url_encode "$value")@${uri_host}:${port}#$(url_encode "${tag}-${name}")"
          print_share_entry "$name" "链接" "$link"
        done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[]|[.username,.password]|@tsv' "$CONFIG_FILE")
      fi
      ;;
  esac
  share_separator
}

print_all_share() {
  ensure_config
  local tag failed=0
  if ! jq -e '.inbounds|length>0' "$CONFIG_FILE" >/dev/null; then info "还没有入站。"; return 0; fi
  while IFS= read -r tag; do
    print_share "$tag" "" || failed=1
  done < <(jq -r '.inbounds[].tag' "$CONFIG_FILE")
  return "$failed"
}

print_subscription() {
  ensure_config
  local selected=${1-} tag line output links=''
  if [[ -n $selected ]] && ! jq -e --arg tag "$selected" '.inbounds[] | select(.tag==$tag)' "$CONFIG_FILE" >/dev/null; then
    warn "找不到可订阅的入站：$selected"
    return 1
  fi
  while IFS= read -r tag; do
    output=$(print_share "$tag") || return 1
    while IFS= read -r line; do
      [[ $line == '链接: '* ]] || continue
      links+="${line#链接: }"$'\n'
    done <<<"$output"
  done < <(jq -r --arg selected "$selected" '.inbounds[] | select($selected=="" or .tag==$selected) | .tag' "$CONFIG_FILE")
  [[ -n $links ]] || { warn "没有可生成订阅的链接。"; return 1; }
  printf '%s' "$links" | base64 | tr -d '\n'
  printf '\n'
}
