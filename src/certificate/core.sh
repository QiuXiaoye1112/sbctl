# shellcheck shell=bash
# Certificate selection, validation, and metadata helpers.

managed_certificate_count() { init_meta; jq -r '.certificates | length' "$META_FILE" 2>/dev/null || printf '0'; }

select_managed_certificate() {
  local __var=$1 always_choose=${2:-0} id answer
  local ids=()
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    [[ -r "$CERT_DIR/${id}.crt" && -r "$CERT_DIR/${id}.key" ]] && ids+=("$id")
  done < <(meta_cert_list)
  ((${#ids[@]} > 0)) || { warn "请在 TLS 证书设置里导入有效证书。"; return 1; }
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

certificate_server_names() {
  local cert=$1 san concrete
  san=$(openssl x509 -in "$cert" -noout -text 2>/dev/null \
    | awk '/X509v3 Subject Alternative Name/ {getline; print; exit}' | tr ',' '\n' \
    | sed -n -e 's/^[[:space:]]*DNS://p' -e 's/^[[:space:]]*IP Address://p')
  if [[ -n $san ]]; then
    concrete=$(printf '%s\n' "$san" | awk '$0 !~ /^\*\./ && !seen[$0]++')
    if [[ -n $concrete ]]; then printf '%s\n' "$concrete"; else printf '%s\n' "$san" | awk '!seen[$0]++'; fi
    return 0
  fi
  openssl x509 -in "$cert" -noout -subject -nameopt RFC2253 2>/dev/null \
    | sed -n 's/^subject=.*CN=\([^,]*\).*$/\1/p'
}

prompt_certificate_server_name() {
  local __var=$1 cert=$2 answer selected name
  local names=()
  while IFS= read -r name; do [[ -n $name ]] && names+=("$name"); done < <(certificate_server_names "$cert")
  if ((${#names[@]} == 0)); then
    while true; do
      prompt_value selected "TLS serverName/SNI" || return 1
      validate_host "$selected" && break
      warn "SNI 必须是有效域名/IP。"
    done
  elif ((${#names[@]} == 1)); then
    selected=${names[0]}
  else
    choose answer "选择 TLS serverName/SNI" "${names[@]}"
    selected=${names[$((answer-1))]}
  fi
  printf -v "$__var" '%s' "$selected"
}

prompt_certificate_files() {
  local __cert=$1 __key=$2 default_cert=${3:-} default_key=${4:-} entered_cert entered_key
  while true; do
    prompt_value entered_cert "证书文件路径" "$default_cert" || return 1
    prompt_value entered_key "私钥文件路径" "$default_key" || return 1
    if validate_certificate_pair "$entered_cert" "$entered_key"; then
      printf -v "$__cert" '%s' "$entered_cert"
      printf -v "$__key" '%s' "$entered_key"
      return 0
    fi
    warn "证书或私钥无效，或证书与私钥不匹配，请重新输入。"
  done
}

prompt_tls_certificate() {
  local __cert=$1 __key=$2 __sni=$3 identifier cert_value key_value sni_value
  if (( $(managed_certificate_count) > 0 )) && confirm "使用托管证书？" Y; then
    select_managed_certificate identifier || return 1
    cert_value="${CERT_DIR}/${identifier}.crt"
    key_value="${CERT_DIR}/${identifier}.key"
    validate_certificate_pair "$cert_value" "$key_value" || { warn "托管证书与私钥校验失败。"; return 1; }
    info "使用托管证书：${identifier}"
  else
    prompt_certificate_files cert_value key_value || return 1
    info "使用证书文件：${cert_value}"
  fi
  prompt_certificate_server_name sni_value "$cert_value" || return 1
  info "TLS serverName/SNI：${sni_value}"
  printf -v "$__cert" '%s' "$cert_value"
  printf -v "$__key" '%s' "$key_value"
  printf -v "$__sni" '%s' "$sni_value"
}

# ---- certificate and managed-resource metadata ----
meta_cert_exists() {
  init_meta
  jq -e --arg id "$1" '.certificates[$id] != null' "$META_FILE" >/dev/null 2>&1
}

meta_cert_set() {
  local identifier=$1 subject=$2 cert_name=$3 source=$4 validation=$5 auto_renew=${6:-true} tmp
  init_meta; tmp=$(temp_file)
  jq --arg id "$identifier" --arg subject "$subject" --arg certName "$cert_name" \
     --arg source "$source" --arg validation "$validation" --arg autoRenew "$auto_renew" \
     --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
    .certificates[$id]={subject:$subject,certName:$certName,source:$source,validation:$validation,
      autoRenew:($autoRenew=="true"),updatedAt:$now}
  ' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
}

meta_cert_delete() {
  local identifier=$1 tmp
  init_meta; tmp=$(temp_file)
  jq --arg id "$identifier" 'del(.certificates[$id])' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
}

meta_cert_get_field() {
  init_meta
  jq -r --arg id "$1" --arg field "$2" '.certificates[$id][$field] | if . == null then empty else . end' "$META_FILE"
}

meta_cert_list() { init_meta; jq -r '.certificates | keys[]' "$META_FILE" 2>/dev/null; }
meta_cert_auto_renew_certs() { init_meta; jq -r '.certificates | to_entries[] | select(.value.autoRenew == true) | .key' "$META_FILE" 2>/dev/null; }

meta_resource_register() {
  local key=$1 value=$2 tmp
  init_meta; tmp=$(temp_file)
  jq --arg key "$key" --arg value "$value" '.managedResources[$key]=$value' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
}

meta_resource_get() { init_meta; jq -r --arg key "$1" '.managedResources[$key] // empty' "$META_FILE"; }

meta_resource_remove() {
  local key=$1 tmp
  init_meta; tmp=$(temp_file)
  jq --arg key "$key" 'del(.managedResources[$key])' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
}
