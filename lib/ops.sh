import_certificate() {
  ensure_dependencies cert-import
  local identifier=${1-} cert=${2-} key=${3-}
  [[ -n $identifier ]] || prompt_value identifier "证书标识/域名"
  [[ $identifier =~ ^[A-Za-z0-9_.-]+$ ]] || die "证书标识无效。"
  [[ -n $cert ]] || prompt_value cert "证书文件路径"
  [[ -n $key ]] || prompt_value key "私钥文件路径"
  validate_certificate_pair "$cert" "$key" || { warn "证书或私钥无效/不匹配。"; return 0; }
  mkdir -p "$CERT_DIR"
  install -m 600 "$cert" "$CERT_DIR/${identifier}.crt"
  install -m 600 "$key" "$CERT_DIR/${identifier}.key"
  info "证书已导入：${identifier}"
}

certbot_supports_ip() {
  command_exists certbot && certbot --help all 2>/dev/null | grep -q -- '--ip-address'
}

install_certbot() {
  local mode=${1:-domain}
  if command_exists certbot; then
    if [[ $mode == ip ]] && ! certbot_supports_ip; then
      warn "当前 Certbot 不支持 IP 证书，请升级 certbot 或使用域名证书。"
      return 0
    fi
    return 0
  fi
  if [[ $mode == ip ]] && ! certbot_supports_ip 2>/dev/null; then
    # 系统 certbot 可能太旧，用 pip 安装新版
    install_packages python3 python3-pip || die "Python/pip 安装失败。"
    pip3 install certbot >/dev/null 2>&1 || install_packages certbot
  else
    install_packages certbot
  fi
}

write_certbot_hook() {
  local domain=$1 hook
  hook="${CERTBOT_HOOK_DIR}/sbctl-${domain}"
  mkdir -p "$(dirname "$hook")"
  case $(init_system) in
    systemd)
      cat >"$hook" <<EOF_HOOK
#!/usr/bin/env bash
set -e
install -m 600 /etc/letsencrypt/live/${domain}/fullchain.pem ${CERT_DIR}/${domain}.crt
install -m 600 /etc/letsencrypt/live/${domain}/privkey.pem ${CERT_DIR}/${domain}.key
systemctl try-restart ${SERVICE_NAME}.service || true
EOF_HOOK
      ;;
    openrc)
      cat >"$hook" <<EOF_HOOK
#!/usr/bin/env bash
set -e
install -m 600 /etc/letsencrypt/live/${domain}/fullchain.pem ${CERT_DIR}/${domain}.crt
install -m 600 /etc/letsencrypt/live/${domain}/privkey.pem ${CERT_DIR}/${domain}.key
rc-service ${SERVICE_NAME} restart || true
EOF_HOOK
      ;;
  esac
  chmod 700 "$hook"
}

setup_certbot_renewal_timer() {
  local certbot_path
  certbot_path=$(command -v certbot) || return 1
  case $(init_system) in
    systemd)
      cat >/etc/systemd/system/sbctl-certbot-renew.service <<EOF
[Unit]
Description=Renew certificates managed by sbctl
[Service]
Type=oneshot
ExecStart=${certbot_path} renew --quiet
EOF
      cat >/etc/systemd/system/sbctl-certbot-renew.timer <<'EOF'
[Unit]
Description=Renew certificates managed by sbctl
[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF
      systemctl daemon-reload
      systemctl enable --now sbctl-certbot-renew.timer >/dev/null
      ;;
    openrc)
      mkdir -p /etc/periodic/daily
      cat >/etc/periodic/daily/sbctl-certbot-renew <<EOF
#!/bin/sh
${certbot_path} renew --quiet
EOF
      chmod 755 /etc/periodic/daily/sbctl-certbot-renew
      ;;
  esac
}

CF_CREDENTIALS_FILE="${SBCTL_CF_CREDENTIALS:-/etc/letsencrypt/cloudflare.ini}"

install_certbot_dns_plugin() {
  local certbot_path certbot_python
  certbot_path=$(command -v certbot 2>/dev/null || true)
  if [[ -n $certbot_path ]]; then
    certbot_python=$(head -1 "$certbot_path" 2>/dev/null | sed 's/^#!//; s/[[:space:]]*$//')
    if [[ -n $certbot_python && -x $certbot_python ]]; then
      if "$certbot_python" -c 'import certbot_dns_cloudflare' 2>/dev/null; then return 0; fi
      info "正在安装 certbot-dns-cloudflare..."
      "$certbot_python" -m pip install certbot-dns-cloudflare >/dev/null 2>&1 && return 0
    fi
  fi
  local manager; manager=$(pkg_manager 2>/dev/null || true)
  case $manager in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y python3-certbot-dns-cloudflare >/dev/null 2>&1 && return 0 ;;
    dnf) dnf install -y python3-certbot-dns-cloudflare >/dev/null 2>&1 && return 0 ;;
    apk) apk add --no-cache py3-certbot-dns-cloudflare >/dev/null 2>&1 && return 0 ;;
  esac
  command_exists pip3 || install_packages python3-pip
  pip3 install certbot-dns-cloudflare >/dev/null 2>&1 || { warn "certbot-dns-cloudflare 安装失败。"; return 1; }
}

issue_certificate() {
  ensure_dependencies cert-issue
  local domain=${1-} email=${2-} active=0 mode=domain verify_method=http default_domain=""
  if [[ -z $domain ]]; then
    default_domain=$(detect_public_ipv4 || true)
    [[ -n $default_domain ]] || default_domain=$(detect_public_ipv6 || true)
    while true; do
      prompt_value domain "证书域名/IP" "$default_domain"
      if validate_ip_literal "$domain"; then mode=ip; break; fi
      if validate_domain "$domain"; then break; fi
      warn "证书域名/IP 无效，请重新输入。"
    done
  else
    if validate_ip_literal "$domain"; then mode=ip
    elif ! validate_domain "$domain"; then die "证书域名/IP 无效。"; fi
  fi

  # 域名可选 DNS 验证，IP 只能用 HTTP
  if [[ $mode == domain ]]; then
    choose verify_method "选择验证方式" "DNS (Cloudflare, 推荐)" "HTTP (需要 80 端口可访问)"
    if [[ $verify_method == 1 ]]; then
      install_certbot_dns_plugin || return 0
      local cf_email cf_key
      prompt_value cf_email "Cloudflare 邮箱"
      [[ -n $cf_email ]] || { warn "邮箱不能为空。"; return 0; }
      prompt_value cf_key "Cloudflare Global API Key"
      [[ -n $cf_key ]] || { warn "API Key 不能为空。"; return 0; }
      mkdir -p "$(dirname "$CF_CREDENTIALS_FILE")"
      printf 'dns_cloudflare_email = %s\ndns_cloudflare_api_key = %s\n' "$cf_email" "$cf_key" >"$CF_CREDENTIALS_FILE"
      chmod 600 "$CF_CREDENTIALS_FILE"
      verify_method=dns
    fi
  fi

  while [[ -z $email ]]; do
    prompt_value email "Let's Encrypt 联系邮箱"
    if [[ $email == *@*.* && $email != *" "* ]]; then break; fi
    warn "邮箱格式无效，请重新输入。"
    email=""
  done
  install_certbot "$mode"
  if [[ -f ${CERT_DIR}/${domain}.crt && -f ${CERT_DIR}/${domain}.key ]]; then
    local using_inbounds
    using_inbounds=$(jq -r --arg cert "${CERT_DIR}/${domain}.crt" \
      '.inbounds[]?|select(.tls.certificate_path==$cert)|.tag' "$CONFIG_FILE" 2>/dev/null | paste -sd ',')
    if [[ -n $using_inbounds ]]; then
      confirm "证书 ${domain} 正在被 ${using_inbounds} 使用，是否强制重新签发？" N || { info "已取消。"; return 0; }
    else
      confirm "证书 ${domain} 已存在，是否强制重新签发？" N || { info "已取消。"; return 0; }
    fi
  fi

  local certbot_args
  if [[ $verify_method == dns ]]; then
    certbot_args=(certonly --non-interactive --agree-tos -m "$email" --force-renewal
      --dns-cloudflare --dns-cloudflare-credentials "$CF_CREDENTIALS_FILE" -d "$domain")
  else
    service_is_active && { active=1; service_stop; CERT_STOPPED_SERVICE=1; }
    certbot_args=(certonly --standalone --non-interactive --agree-tos --preferred-challenges http -m "$email" --force-renewal)
    if [[ $mode == ip ]]; then
      certbot_args+=(--preferred-profile shortlived --ip-address "$domain")
    else
      certbot_args+=(-d "$domain")
    fi
  fi
  setup_certbot_renewal_timer
  if ! certbot "${certbot_args[@]}"; then
    if ((active)); then service_start; CERT_STOPPED_SERVICE=0; fi
    warn "证书签发失败，请查看上方 Certbot 输出的具体原因。"
    if [[ $verify_method == dns ]]; then
      warn "提示：确认 Cloudflare 邮箱和 Global API Key 正确，且域名在账户中。"
    fi
    return 0
  fi
  mkdir -p "$CERT_DIR"
  install -m 600 "/etc/letsencrypt/live/${domain}/fullchain.pem" "$CERT_DIR/${domain}.crt"
  install -m 600 "/etc/letsencrypt/live/${domain}/privkey.pem" "$CERT_DIR/${domain}.key"
  write_certbot_hook "$domain"
  if ((active)); then
    service_start; CERT_STOPPED_SERVICE=0
  elif [[ $verify_method == dns ]] && service_is_active; then
    service_restart
  fi
  info "证书已签发并托管：${domain}"
}

list_certificates() {
  local cert found=0
  for cert in "$CERT_DIR"/*.crt; do
    [[ -r $cert ]] || continue
    found=1
    printf '%s\n' "$(basename "$cert" .crt)"
    openssl x509 -in "$cert" -noout -subject -issuer -dates 2>/dev/null | sed 's/^/  /'
  done
  ((found)) || info "没有托管证书。"
}

delete_certificate() {
  ensure_dependencies cert-delete
  local identifier=${1-}
  [[ -n $identifier ]] || select_managed_certificate identifier || return
  if jq -e --arg cert "$CERT_DIR/${identifier}.crt" '.inbounds[]?|select(.tls.certificate_path==$cert)' "$CONFIG_FILE" >/dev/null; then warn "该证书正在被入站使用，不能删除。"; return 0; fi
  confirm "删除托管证书 ${identifier}？" N || return
  rm -f "$CERT_DIR/${identifier}.crt" "$CERT_DIR/${identifier}.key" "/etc/letsencrypt/renewal-hooks/deploy/sbctl-${identifier}"
  info "证书已删除。"
}

backup_all() {
  require_root backup; ensure_config
  local target=${1:-${BACKUP_DIR}/sbctl-$(timestamp).tar.gz} paths=("${CONFIG_FILE#/}" "${META_FILE#/}")
  mkdir -p "$BACKUP_DIR" "$(dirname "$target")"
  [[ ! -d $CERT_DIR ]] || paths+=("${CERT_DIR#/}")
  tar -czf "$target" -C / "${paths[@]}" || die "备份失败。"
  chmod 600 "$target"
  info "备份已创建：$target"
}

restore_backup() {
  ensure_dependencies restore; ensure_config
  local archive=${1-} temp extract_config snapshot had_meta=0 had_certs=0
  [[ -n $archive ]] || prompt_value archive "备份文件路径"
  [[ -r $archive ]] || die "无法读取备份。"
  tar -tzf "$archive" >/dev/null || { warn "不是有效的 tar.gz 备份。"; return 0; }
  if tar -tzf "$archive" | awk 'BEGIN{bad=0} /^\// || /(^|\/)\.\.($|\/)/ {bad=1} END{exit !bad}'; then die "备份包含不安全路径。"; fi
  extract_config="${CONFIG_FILE#/}"
  temp=$(mktemp -d "${TMPDIR:-/tmp}/sbctl-restore.XXXXXX")
  tar -xzf "$archive" -C "$temp"
  [[ -f $temp/$extract_config ]] || { rm -rf "$temp"; die "备份中没有配置文件。"; }
  validate_candidate "$temp/$extract_config" || { rm -rf "$temp"; die "备份配置验证失败。"; }
  confirm "恢复会覆盖当前配置、元数据和托管证书，继续？" N || { rm -rf "$temp"; return; }
  snapshot="$temp/.current"; mkdir -p "$snapshot"
  cp -a "$CONFIG_FILE" "$snapshot/config.json"
  [[ ! -f $META_FILE ]] || { cp -a "$META_FILE" "$snapshot/meta.json"; had_meta=1; }
  [[ ! -d $CERT_DIR ]] || { cp -a "$CERT_DIR" "$snapshot/certs"; had_certs=1; }
  cp -a "$temp/$extract_config" "$CONFIG_FILE"
  if [[ -f $temp/${META_FILE#/} ]]; then cp -a "$temp/${META_FILE#/}" "$META_FILE"; else rm -f "$META_FILE"; fi
  init_meta
  rm -rf "$CERT_DIR"; mkdir -p "$CERT_DIR"
  [[ ! -d $temp/${CERT_DIR#/} ]] || cp -a "$temp/${CERT_DIR#/}/." "$CERT_DIR/"
  if ! restart_service_checked; then
    error "恢复后服务失败，正在整体回滚。"
    cp -a "$snapshot/config.json" "$CONFIG_FILE"
    ((had_meta)) && cp -a "$snapshot/meta.json" "$META_FILE" || rm -f "$META_FILE"
    init_meta
    rm -rf "$CERT_DIR"; mkdir -p "$CERT_DIR"
    ((had_certs)) && cp -a "$snapshot/certs/." "$CERT_DIR/" || true
    restart_service_checked || true
    rm -rf "$temp"
    die "恢复失败，已回滚 config/meta/certs。"
  fi
  rm -rf "$temp"
  info "备份已恢复。"
}

edit_config() {
  ensure_dependencies config-edit; ensure_config
  local editor=${EDITOR:-vi} tmp
  tmp=$(temp_file); cp -a "$CONFIG_FILE" "$tmp"
  "$editor" "$tmp"
  if cmp -s "$tmp" "$CONFIG_FILE"; then info "配置未更改。"; else apply_candidate "$tmp"; fi
  rm -f "$tmp"
}
check_config() { ensure_config; require_supported_core; validate_candidate "$CONFIG_FILE" && info "配置检查通过。"; }

service_action() {
  ensure_dependencies service
  local action=$1
  service_exists || die "sing-box 服务不存在。"
  case $action in
    start) service_start;; stop) service_stop;; restart) service_restart;;
    enable) service_enable; service_start;; disable) service_disable; service_stop;;
    *) die "未知服务操作：$action";;
  esac
  info "服务操作完成：${action}"
}

show_status() {
  heading "sing-box 状态"
  refresh_binary_path
  if sing_box_installed; then "$SING_BOX_BIN" version | sed -n '1,2p'; else printf 'sing-box: 未安装\n'; fi
  printf '初始化系统: %s\n' "$(init_system)"
  if service_exists; then
    if service_is_active; then printf '服务: 运行中\n'; else printf '服务: 已停止\n'; fi
    if service_is_enabled; then printf '开机自启: 已开启\n'; else printf '开机自启: 已关闭\n'; fi
  else printf '服务: 未安装\n'; fi
  [[ -f $CONFIG_FILE ]] && printf '入站数: %s\n配置: %s\n' "$(jq '.inbounds|length' "$CONFIG_FILE" 2>/dev/null || printf '?')" "$CONFIG_FILE"
}

node_summary() {
  refresh_binary_path
  local version=未安装 service=未安装 count=0
  sing_box_installed && version=$($SING_BOX_BIN version 2>/dev/null | sed -n '1s/^sing-box version //p')
  service_exists && { service_is_active && service=运行中 || service=已停止; }
  [[ -f $CONFIG_FILE ]] && count=$(jq '.inbounds|length' "$CONFIG_FILE" 2>/dev/null || printf 0)
  printf '服务: %s  |  入站: %s  |  sing-box: %s\n' "$service" "$count" "${version:-已安装}"
}
