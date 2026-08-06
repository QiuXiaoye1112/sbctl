# shellcheck shell=bash
# TLS certificate server-name helpers aligned with xrayctl.
# Canonical select_managed_certificate and build_certificate_tls live in inbound.sh.

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
