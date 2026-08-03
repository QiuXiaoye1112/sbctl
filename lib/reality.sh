# REALITY interaction helpers.
# Keeps handshake target and port in one prompt, e.g. www.microsoft.com:443.

build_reality_tls() {
  local __json=$1 __public=$2 endpoint target port sni
  local __generated_private __generated_public short_id

  prompt_value endpoint "REALITY 握手目标" "www.microsoft.com:443"
  if [[ $endpoint == *:* ]]; then
    target=${endpoint%:*}
    port=${endpoint##*:}
  else
    target=$endpoint
    port=443
  fi

  validate_domain "$target" || die "REALITY 握手目标必须是域名，格式如 www.microsoft.com:443。"
  validate_port "$port" || die "REALITY 握手端口必须为 1-65535。"
  prompt_value sni "REALITY serverName/SNI" "$target"
  validate_domain "$sni" || die "SNI 必须是域名。"

  generate_reality_keys __generated_private __generated_public
  short_id=$(random_hex 4)
  printf -v "$__json" '%s' "$(jq -n --arg sni "$sni" --arg server "$target" --argjson port "$port" --arg private "$__generated_private" --arg sid "$short_id" '{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$server,server_port:$port},private_key:$private,short_id:[$sid]}}')"
  printf -v "$__public" '%s' "$__generated_public"
}
