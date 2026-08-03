import_certificate() {
  ensure_dependencies cert-import
  local identifier=${1-} cert=${2-} key=${3-}
  [[ -n $identifier ]] || prompt_value identifier "证书标识/域名"
  [[ $identifier =~ ^[A-Za-z0-9_.-]+$ ]] || die "证书标识无效。"
  [[ -n $cert ]] || prompt_value cert "证书文件路径"
  [[ -n $key ]] || prompt_value key "私钥文件路径"
  validate_certificate_pair "$cert" "$key" || die "证书或私钥无效/不匹配。"
  mkdir -p "$CERT_DIR"
  install -m 600 "$cert" "$CERT_DIR/${identifier}.crt"
  install -m 600 "$key" "$CERT_DIR/${identifier}.key"
  info "证书已导入：${identifier}"
}

install_certbot() {
  command_exists certbot && return 0
  install_packages certbot
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

issue_certificate() {
  ensure_dependencies cert-issue
  local domain=${1-} email=${2-} active=0
  [[ -n $domain ]] || prompt_value domain "证书域名"
  validate_domain "$domain" || die "目前自动签发只支持域名证书。"
  [[ -n $email ]] || prompt_value email "Let's Encrypt 联系邮箱"
  install_certbot
  service_is_active && { active=1; service_stop; CERT_STOPPED_SERVICE=1; }
  if ! certbot certonly --standalone --non-interactive --agree-tos --preferred-challenges http -m "$email" -d "$domain"; then
    die "证书签发失败；确认域名解析正确且 TCP 80 可访问。"
  fi
  mkdir -p "$CERT_DIR"
  install -m 600 "/etc/letsencrypt/live/${domain}/fullchain.pem" "$CERT_DIR/${domain}.crt"
  install -m 600 "/etc/letsencrypt/live/${domain}/privkey.pem" "$CERT_DIR/${domain}.key"
  write_certbot_hook "$domain"
  if ((active)); then service_start; CERT_STOPPED_SERVICE=0; fi
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
  if jq -e --arg cert "$CERT_DIR/${identifier}.crt" '.inbounds[]?|select(.tls.certificate_path==$cert)' "$CONFIG_FILE" >/dev/null; then die "该证书正在被入站使用，不能删除。"; fi
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
  tar -tzf "$archive" >/dev/null || die "不是有效 tar.gz。"
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
