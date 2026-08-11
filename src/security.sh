# shellcheck shell=bash
# TLS and REALITY configuration used by protocol builders.

validate_reality_target() {
  local value=$1 host port
  [[ $value == *:* ]] || return 1
  host=${value%:*}
  port=${value##*:}
  [[ -n $host ]] && validate_port "$port"
}

build_certificate_tls() {
  local __json=$1 __host=${2-} identifier sni
  select_managed_certificate identifier || return 1
  prompt_certificate_server_name sni "$CERT_DIR/${identifier}.crt" || return 1
  printf -v "$__json" '%s' "$(jq -n --arg sni "$sni" --arg cert "$CERT_DIR/${identifier}.crt" --arg key "$CERT_DIR/${identifier}.key" '{enabled:true,server_name:$sni,certificate_path:$cert,key_path:$key,min_version:"1.2"}')"
  [[ -z $__host ]] || printf -v "$__host" '%s' "$sni"
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
  sni=${target%:*}; port=${target##*:}
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
