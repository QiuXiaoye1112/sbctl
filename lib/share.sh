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
  ensure_config
  local tag=${1-} filter=${2-} type host uri_host port name value flow sni public sid security tls_enabled obfs obfs_password link json
  [[ -n $tag ]] || select_inbound tag || return 0
  inbound_exists "$tag" || die "找不到入站：$tag"
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
  host=$(public_host_for_tag "$tag") || warn "无法确定入站 ${tag} 的客户端连接地址。"
  uri_host=$(uri_host "$host")
  port=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen_port' "$CONFIG_FILE")
  heading "${tag} 分享信息"

  case $type in
    vless)
      sni=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.server_name // empty' "$CONFIG_FILE")
      tls_enabled=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.enabled // false' "$CONFIG_FILE")
      if jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.reality.enabled==true' "$CONFIG_FILE" >/dev/null; then
        security=reality
        public=$(reality_public_key "$tag") || { warn "无法获得 REALITY 公钥。"; return 0; }
        sid=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.reality.short_id[0]' "$CONFIG_FILE")
      elif [[ $tls_enabled == true ]]; then
        security=tls
      else
        warn "VLESS 入站未启用 TLS/REALITY，无法生成分享链接。"; return 0
      fi
      while IFS=$'\t' read -r name value flow; do
        [[ -z $filter || $name == "$filter" ]] || continue
        if [[ $security == reality ]]; then
          link="vless://${value}@${uri_host}:${port}?type=tcp&security=reality&sni=$(url_encode "$sni")&fp=chrome&pbk=$(url_encode "$public")&sid=$(url_encode "$sid")&spx=%2F"
          [[ -n $flow ]] && link+="&flow=$(url_encode "$flow")"
        else
          link="vless://${value}@${uri_host}:${port}?type=tcp&security=tls&sni=$(url_encode "$sni")"
        fi
        link+="#$(url_encode "${tag}-${name}")"
        print_share_entry "$name" "链接" "$link"
      done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[]|[.name,.uuid,(.flow//"")]|@tsv' "$CONFIG_FILE")
      ;;

    trojan)
      sni=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.server_name // empty' "$CONFIG_FILE")
      tls_enabled=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.enabled // false' "$CONFIG_FILE")
      if jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.reality.enabled==true' "$CONFIG_FILE" >/dev/null; then
        security=reality
        public=$(reality_public_key "$tag") || { warn "无法获得 REALITY 公钥。"; return 0; }
        sid=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.reality.short_id[0]' "$CONFIG_FILE")
      elif [[ $tls_enabled == true ]]; then
        security=tls
      else
        warn "Trojan 入站未启用 TLS/REALITY，无法生成分享链接。"; return 0
      fi
      while IFS=$'\t' read -r name value; do
        [[ -z $filter || $name == "$filter" ]] || continue
        if [[ $security == reality ]]; then
          link="trojan://$(url_encode "$value")@${uri_host}:${port}?type=tcp&security=reality&sni=$(url_encode "$sni")&fp=chrome&pbk=$(url_encode "$public")&sid=$(url_encode "$sid")&spx=%2F"
        else
          link="trojan://$(url_encode "$value")@${uri_host}:${port}?type=tcp&security=tls&sni=$(url_encode "$sni")"
        fi
        link+="#$(url_encode "${tag}-${name}")"
        print_share_entry "$name" "链接" "$link"
      done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[]|[.name,.password]|@tsv' "$CONFIG_FILE")
      ;;

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
          json=$(client_json_for_anytls "$tag" "$name")
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
      if [[ $(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.users//[])|length' "$CONFIG_FILE") == 0 ]]; then
        link="${type}://${uri_host}:${port}  无认证"
        print_share_entry "无认证" "链接" "$link"
      else
        while IFS=$'\t' read -r name value; do
          [[ -z $filter || $name == "$filter" ]] || continue
          link="${type}://$(url_encode "$name"):$(url_encode "$value")@${uri_host}:${port}#$(url_encode "${tag}-${name}")"
          print_share_entry "$name" "链接" "$link"
        done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[]|[.username,.password]|@tsv' "$CONFIG_FILE")
      fi
      ;;
    *)
      warn "该入站协议不提供 sbctl 分享信息：${type}"; return 0
      ;;
  esac
  share_separator
}
