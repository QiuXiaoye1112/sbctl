# REALITY interaction helpers aligned with xrayctl.

validate_reality_target() {
  local value=$1 host port
  [[ $value == *:* ]] || return 1
  host=${value%:*}
  port=${value##*:}
  [[ -n $host ]] && validate_port "$port"
}

build_reality_tls() {
  local __json=$1 __public=$2 target host port sni
  local __generated_private __generated_public short_id

  while true; do
    prompt_value target "REALITY 目标" "www.microsoft.com:443" || return 1
    validate_reality_target "$target" && break
    warn "目标格式应为 域名:端口，请重新输入。"
  done

  host=${target%:*}
  port=${target##*:}
  while true; do
    prompt_value sni "REALITY serverName/SNI" "$host" || return 1
    validate_domain "$sni" && break
    warn "SNI 必须是有效域名，请重新输入。"
  done

  generate_reality_keys __generated_private __generated_public
  short_id=$(random_hex 8)
  printf -v "$__json" '%s' "$(jq -n --arg sni "$sni" --arg server "$host" --argjson port "$port" --arg private "$__generated_private" --arg sid "$short_id" '{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$server,server_port:$port},private_key:$private,short_id:[$sid]}}')"
  printf -v "$__public" '%s' "$__generated_public"
}
