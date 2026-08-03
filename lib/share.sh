# Share-output overrides aligned with xrayctl's interaction style.

_share_separator() {
  printf '%s\n' '------------------------------------------------------------------------'
}

print_share() {
  ensure_config
  local tag=${1-} filter=${2-} type host h port name value flow sni public sid security tls_enabled obfs obfs_password
  [[ -n $tag ]] || select_inbound tag || return
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
  host=$(public_host_for_tag "$tag") || die "无法确定入站 ${tag} 的客户端连接地址。"
  h=$(uri_host "$host")
  port=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen_port' "$CONFIG_FILE")

  heading "${tag} 分享信息"
  _share_separator

  case $type in
    vless)
      sni=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.server_name // empty' "$CONFIG_FILE")
      tls_enabled=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.enabled // false' "$CONFIG_FILE")
      if jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.reality.enabled==true' "$CONFIG_FILE" >/dev/null; then
        security=reality
        public=$(reality_public_key "$tag") || die "REALITY 公钥元数据缺失或与当前私钥不匹配。"
        sid=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.reality.short_id[0]' "$CONFIG_FILE")
      elif [[ $tls_enabled == true ]]; then
        security=tls
      else
        die "VLESS 入站未启用 TLS/REALITY，无法生成分享链接。"
      fi
      while IFS=$'\t' read -r name value flow; do
        [[ -z $filter || $name == "$filter" ]] || continue
        printf '用户: %s\n' "$name"
        if [[ $security == reality ]]; then
          printf '链接: vless://%s@%s:%s?type=tcp&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&spx=%%2F' \
            "$value" "$h" "$port" "$(url_encode "$sni")" "$(url_encode "$public")" "$(url_encode "$sid")"
          [[ -z $flow ]] || printf '&flow=%s' "$(url_encode "$flow")"
          printf '#%s\n' "$(url_encode "${tag}-${name}")"
        else
          printf '链接: vless://%s@%s:%s?type=tcp&security=tls&sni=%s#%s\n' \
            "$value" "$h" "$port" "$(url_encode "$sni")" "$(url_encode "${tag}-${name}")"
        fi
        _share_separator
      done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[]|[.name,.uuid,(.flow//"")]|@tsv' "$CONFIG_FILE")
      ;;

    trojan)
      sni=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.server_name // empty' "$CONFIG_FILE")
      tls_enabled=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.enabled // false' "$CONFIG_FILE")
      if jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.reality.enabled==true' "$CONFIG_FILE" >/dev/null; then
        security=reality
        public=$(reality_public_key "$tag") || die "REALITY 公钥元数据缺失或与当前私钥不匹配。"
        sid=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.reality.short_id[0]' "$CONFIG_FILE")
      elif [[ $tls_enabled == true ]]; then
        security=tls
      else
        die "Trojan 入站未启用 TLS/REALITY，无法生成分享链接。"
      fi
      while IFS=$'\t' read -r name value; do
        [[ -z $filter || $name == "$filter" ]] || continue
        printf '用户: %s\n' "$name"
        if [[ $security == reality ]]; then
          printf '链接: trojan://%s@%s:%s?type=tcp&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&spx=%%2F#%s\n' \
            "$(url_encode "$value")" "$h" "$port" "$(url_encode "$sni")" "$(url_encode "$public")" "$(url_encode "$sid")" "$(url_encode "${tag}-${name}")"
        else
          printf '链接: trojan://%s@%s:%s?type=tcp&security=tls&sni=%s#%s\n' \
            "$(url_encode "$value")" "$h" "$port" "$(url_encode "$sni")" "$(url_encode "${tag}-${name}")"
        fi
        _share_separator
      done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[]|[.name,.password]|@tsv' "$CONFIG_FILE")
      ;;

    hysteria2)
      jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.enabled==true' "$CONFIG_FILE" >/dev/null || die "Hysteria2 必须启用 TLS。"
      sni=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.server_name' "$CONFIG_FILE")
      obfs=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.obfs.type // empty' "$CONFIG_FILE")
      obfs_password=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.obfs.password // empty' "$CONFIG_FILE")
      while IFS=$'\t' read -r name value; do
        [[ -z $filter || $name == "$filter" ]] || continue
        printf '用户: %s\n链接: hysteria2://%s@%s:%s?sni=%s' "$name" "$(url_encode "$value")" "$h" "$port" "$(url_encode "$sni")"
        [[ -z $obfs ]] || printf '&obfs=%s&obfs-password=%s' "$(url_encode "$obfs")" "$(url_encode "$obfs_password")"
        printf '#%s\n' "$(url_encode "${tag}-${name}")"
        _share_separator
      done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[]|[.name,.password]|@tsv' "$CONFIG_FILE")
      ;;

    anytls)
      while IFS= read -r name; do
        [[ -z $filter || $name == "$filter" ]] || continue
        printf '用户: %s\n客户端 outbound JSON:\n' "$name"
        client_json_for_anytls "$tag" "$name"
        printf '\n'
        _share_separator
      done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[].name' "$CONFIG_FILE")
      ;;

    socks|http|mixed)
      if [[ $(jq --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.users//[])|length' "$CONFIG_FILE") == 0 ]]; then
        printf '链接: %s://%s:%s\n' "$type" "$h" "$port"
        _share_separator
      else
        while IFS=$'\t' read -r name value; do
          [[ -z $filter || $name == "$filter" ]] || continue
          printf '用户: %s\n链接: %s://%s:%s@%s:%s\n' "$name" "$type" "$(url_encode "$name")" "$(url_encode "$value")" "$h" "$port"
          _share_separator
        done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[]|[.username,.password]|@tsv' "$CONFIG_FILE")
      fi
      ;;
  esac
}
