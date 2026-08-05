# Cloudflare DNS validation and credential management.
# Loaded after enhancements.sh so it can extend the certificate lifecycle.

CLOUDFLARE_INI="${SBCTL_CLOUDFLARE_INI:-${CERTBOT_CONFIG_DIR}/cloudflare.ini}"

# Preserve the v0.3 certificate/CLI implementations and extend Cloudflare paths.
eval "$(declare -f renew_one_certificate | sed '1s/^renew_one_certificate[[:space:]]*()/_sbctl_cf_base_renew_one_certificate ()/')"
eval "$(declare -f dispatch | sed '1s/^dispatch[[:space:]]*()/_sbctl_cf_base_dispatch ()/')"

cloudflare_plugin_available() {
  [[ -x $CERTBOT_VENV/bin/python ]] && "$CERTBOT_VENV/bin/python" -c 'import certbot_dns_cloudflare' >/dev/null 2>&1
}

ensure_cloudflare_certbot_plugin() {
  cloudflare_plugin_available && return 0
  [[ -x $CERTBOT_VENV/bin/pip ]] || { warn "Certbot venv 缺少 pip，无法安装 Cloudflare DNS 插件。"; return 1; }
  info "正在安装 Certbot Cloudflare DNS 插件。"
  _cert_run_bounded 180 "$CERTBOT_VENV/bin/pip" install --disable-pip-version-check --timeout 20 --retries 2 \
    --upgrade certbot-dns-cloudflare >/dev/null || { warn "certbot-dns-cloudflare 安装失败。"; return 1; }
  cloudflare_plugin_available || { warn "Cloudflare DNS 插件安装后仍不可用。"; return 1; }
}

load_cloudflare_credentials() {
  [[ -f $CLOUDFLARE_INI && -r $CLOUDFLARE_INI ]] || return 1
  grep -Eq '^[[:space:]]*dns_cloudflare_email[[:space:]]*=[[:space:]]*[^[:space:]].*$' "$CLOUDFLARE_INI" || return 1
  grep -Eq '^[[:space:]]*dns_cloudflare_api_key[[:space:]]*=[[:space:]]*[^[:space:]].*$' "$CLOUDFLARE_INI"
}

cloudflare_dependent_certificates() {
  init_meta
  jq -r '.certificates | to_entries[] | select(.value.validation == "dns-cloudflare") | .key' "$META_FILE" 2>/dev/null
}

cloudflare_dependency_count() {
  local deps
  deps=$(cloudflare_dependent_certificates)
  [[ -n $deps ]] && printf '%s\n' "$deps" | grep -c . || printf '0'
}

prompt_cloudflare_api_key() {
  local __var=$1 key=""
  while [[ -z $key ]]; do
    if [[ -t 0 ]]; then
      printf 'Cloudflare Global API Key: '
      read -r -s key || { printf '\n'; return 1; }
      printf '\n'
    else
      read -r key || return 1
    fi
    [[ -n $key ]] || warn "API Key 不能为空。"
  done
  [[ $key != *$'\n'* && $key != *$'\r'* ]] || { warn "API Key 格式无效。"; return 1; }
  printf -v "$__var" '%s' "$key"
}

save_cloudflare_credentials() {
  local email=${1-} api_key=${2-} tmp
  while [[ -z $email ]]; do
    prompt_value email "Cloudflare 邮箱" || return 1
    validate_email_address "$email" || { warn "邮箱格式无效。"; email=""; }
  done
  validate_email_address "$email" || { warn "邮箱格式无效。"; return 1; }
  [[ -n $api_key ]] || prompt_cloudflare_api_key api_key || return 1
  [[ $api_key != *$'\n'* && $api_key != *$'\r'* ]] || { warn "API Key 格式无效。"; return 1; }

  mkdir -p "$(dirname "$CLOUDFLARE_INI")"
  tmp=$(temp_file)
  printf 'dns_cloudflare_email = %s\ndns_cloudflare_api_key = %s\n' "$email" "$api_key" >"$tmp"
  install -m 600 "$tmp" "$CLOUDFLARE_INI"
  rm -f "$tmp"
  meta_resource_register cloudflareCredentials "$CLOUDFLARE_INI"
  info "Cloudflare Global API Key 已保存：${CLOUDFLARE_INI}"
}

delete_cloudflare_credentials() {
  local deps
  load_cloudflare_credentials || { info "尚未配置 Cloudflare Global API Key。"; return 0; }
  deps=$(cloudflare_dependent_certificates)
  if [[ -n $deps ]]; then
    warn "以下证书依赖 Cloudflare 凭据自动续期："
    while IFS= read -r id; do [[ -n $id ]] && printf '  - %s\n' "$id" >&2; done <<<"$deps"
    confirm "删除后这些证书将无法自动续期，仍然删除？" N || { info "已取消。"; return 0; }
  else
    confirm "删除 Cloudflare Global API Key？" N || return 0
  fi
  rm -f "$CLOUDFLARE_INI"
  meta_resource_remove cloudflareCredentials
  info "Cloudflare 凭据已删除。"
}

cloudflare_credentials_menu() {
  local choice email=""
  while true; do
    clear_screen; heading "Cloudflare DNS 凭据"
    if load_cloudflare_credentials; then
      email=$(sed -n 's/^[[:space:]]*dns_cloudflare_email[[:space:]]*=[[:space:]]*//p' "$CLOUDFLARE_INI" | head -1)
      printf 'Cloudflare 邮箱: %s\nGlobal API Key: 已配置\n' "${email:-未知}"
    else
      printf 'Cloudflare 凭据: 未配置\n'
    fi
    printf '依赖自动续期证书: %s\n\n' "$(cloudflare_dependency_count)"
    printf '1) 设置/替换邮箱和 Global API Key\n2) 删除凭据\n0) 返回\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action save_cloudflare_credentials; pause;;
      2) run_menu_action delete_cloudflare_credentials; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

_issue_domain_cloudflare() {
  local domain=$1 email=$2 force=$3
  load_cloudflare_credentials || { warn "Cloudflare 邮箱 / Global API Key 未配置。"; return 1; }
  ensure_cloudflare_certbot_plugin || return 1
  local args=(certonly --dns-cloudflare --dns-cloudflare-credentials "$CLOUDFLARE_INI" \
    --dns-cloudflare-propagation-seconds 10 --non-interactive --agree-tos --cert-name "$domain" -m "$email" -d "$domain")
  [[ $force == 1 ]] && args+=(--force-renewal)
  certbot_cmd "${args[@]}"
}

issue_certificate() {
  ensure_dependencies cert-issue
  ensure_certbot_environment
  local subject=${1-} email=${2-} mode=domain verify_method="" identifier cert_name validation auto_renew=false force=0 changed=0
  if [[ -z $subject ]]; then
    local default_subject=""
    default_subject=$(detect_public_ipv4 || true); [[ -n $default_subject ]] || default_subject=$(detect_public_ipv6 || true)
    while true; do
      prompt_value subject "证书域名/IP" "$default_subject" || return 1
      validate_host "$subject" && break
      warn "证书域名/IP 无效。"
    done
  fi
  if validate_ip_literal "$subject"; then mode=ip; elif ! validate_domain "$subject"; then die "证书域名/IP 无效。"; fi
  identifier=$(certificate_identifier_for_subject "$subject"); cert_name=$identifier
  [[ $mode == domain ]] && cert_name=$subject

  if [[ $mode == domain ]]; then
    choose verify_method "选择验证方式" \
      "Cloudflare DNS（自动验证/自动续期）" \
      "HTTP（自动续期，需要 80 端口）" \
      "DNS（手动添加 TXT，不自动续期）" || return 1
    case $verify_method in
      1) verify_method=dns-cloudflare;;
      2) verify_method=http;;
      3) verify_method=dns-manual;;
    esac
    if [[ $verify_method == dns-cloudflare ]] && ! load_cloudflare_credentials; then
      info "首次使用 Cloudflare DNS 自动验证，需要配置 Cloudflare 邮箱和 Global API Key。"
      save_cloudflare_credentials || return 1
    fi
  fi

  while [[ -z $email ]]; do
    prompt_value email "Let's Encrypt 联系邮箱" || return 1
    validate_email_address "$email" || { warn "邮箱格式无效。"; email=""; }
  done
  validate_email_address "$email" || die "邮箱格式无效。"

  if meta_cert_exists "$identifier" || [[ -f $CERT_DIR/${identifier}.crt || -f $CERT_DIR/${identifier}.key ]]; then
    local users
    users=$(certificate_inbound_users "$identifier" 2>/dev/null || true)
    [[ -z $users ]] || warn "证书正在被入站使用：$(paste -sd ',' <<<"$users")"
    confirm "证书 ${identifier} 已存在，是否强制重新签发？" N || { info "已取消。"; return 0; }
    force=1
  fi

  if [[ $mode == ip ]]; then
    validation=http-standalone; auto_renew=true
    _issue_ip_certificate "$subject" "$email" "$force" || { warn "证书签发失败。"; return 1; }
  elif [[ $verify_method == dns-cloudflare ]]; then
    validation=dns-cloudflare; auto_renew=true
    _issue_domain_cloudflare "$subject" "$email" "$force" || { warn "Cloudflare DNS 证书签发失败。"; return 1; }
  elif [[ $verify_method == dns-manual ]]; then
    validation=dns-manual; auto_renew=false
    _issue_domain_manual_dns "$subject" "$email" "$force" || { warn "证书签发失败。"; return 1; }
  else
    _issue_domain_http "$subject" "$email" "$force" validation || { warn "证书签发失败。"; return 1; }
    auto_renew=true
  fi

  sync_managed_certificate "$identifier" "$cert_name" changed || { warn "证书已签发，但同步到 sbctl 托管目录失败。"; return 1; }
  meta_cert_set "$identifier" "$subject" "$cert_name" letsencrypt "$validation" "$auto_renew"
  [[ $auto_renew == true ]] && setup_certbot_renewal_timer
  restart_sing_box_if_certificate_changed "$changed" || return 1
  info "证书已签发并托管：${identifier}"
}

renew_one_certificate() {
  local identifier=$1 __result_var=${2:-} validation cert_name before_serial="" after_serial="" changed=0 result=failed
  validation=$(meta_cert_get_field "$identifier" validation 2>/dev/null || true)
  [[ $validation == dns-cloudflare ]] || { _sbctl_cf_base_renew_one_certificate "$@"; return; }

  if ! load_cloudflare_credentials; then
    warn "${identifier}: Cloudflare 邮箱 / Global API Key 缺失，自动续期阻塞。"
    [[ -z $__result_var ]] || printf -v "$__result_var" '%s' blocked
    return 0
  fi
  if ! ensure_cloudflare_certbot_plugin; then
    warn "${identifier}: Cloudflare DNS 插件不可用。"
    [[ -z $__result_var ]] || printf -v "$__result_var" '%s' failed
    return 1
  fi
  cert_name=$(meta_cert_get_field "$identifier" certName)
  [[ -n $cert_name ]] || { warn "${identifier}: 缺少 Certbot 名称。"; [[ -z $__result_var ]] || printf -v "$__result_var" '%s' failed; return 1; }
  [[ -r $CERTBOT_CONFIG_DIR/live/${cert_name}/fullchain.pem ]] && before_serial=$(openssl x509 -in "$CERTBOT_CONFIG_DIR/live/${cert_name}/fullchain.pem" -noout -serial 2>/dev/null || true)
  if ! certbot_cmd renew --cert-name "$cert_name" --quiet; then
    warn "证书续期失败：${identifier}"
    [[ -z $__result_var ]] || printf -v "$__result_var" '%s' failed
    return 1
  fi
  [[ -r $CERTBOT_CONFIG_DIR/live/${cert_name}/fullchain.pem ]] && after_serial=$(openssl x509 -in "$CERTBOT_CONFIG_DIR/live/${cert_name}/fullchain.pem" -noout -serial 2>/dev/null || true)
  sync_managed_certificate "$identifier" "$cert_name" changed || { [[ -z $__result_var ]] || printf -v "$__result_var" '%s' failed; return 1; }
  restart_sing_box_if_certificate_changed "$changed" || { [[ -z $__result_var ]] || printf -v "$__result_var" '%s' failed; return 1; }
  if [[ -n $before_serial && -n $after_serial && $before_serial != "$after_serial" ]]; then result=renewed; else result=unchanged; fi
  [[ -z $__result_var ]] || printf -v "$__result_var" '%s' "$result"
}

certificate_menu() {
  local choice
  while true; do
    clear_screen; heading "TLS 证书"
    printf '托管证书: %s\n\n' "$(managed_certificate_count)"
    printf "1) Let's Encrypt 签发\n2) 导入已有证书\n3) 查看托管证书\n4) 删除托管证书\n5) Cloudflare DNS 凭据\n6) 立即检查/续期自动证书\n0) 返回\n"
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action issue_certificate; pause;;
      2) run_menu_action import_certificate; pause;;
      3) run_menu_action list_certificates; pause;;
      4) run_menu_action delete_certificate; pause;;
      5) cloudflare_credentials_menu;;
      6) run_menu_action renew_managed_certificates; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

show_help() {
  cat <<'EOF_HELP'
sbctl - sing-box Linux 管理器

用法:
  sbctl                              打开交互菜单
  sbctl install [版本]               安装/更新 sing-box
  sbctl uninstall                    仅卸载 sing-box 核心，保留配置
  sbctl uninstall --purge            完全卸载，保留备份
  sbctl uninstall --erase            彻底删除全部 sbctl 数据和备份
  sbctl status                       查看状态
  sbctl start|stop|restart           服务控制
  sbctl enable|disable               开关开机自启
  sbctl logs [行数]                  查看日志

  sbctl inbound list|add|show|rename|modify|security|delete
  sbctl outbound list|add|assign|delete
  sbctl client list|add|rename|rotate|delete
  sbctl link [标签] [用户]
  sbctl config check|show|edit

  sbctl cert list
  sbctl cert issue [域名/IP] [邮箱]
  sbctl cert import [标识] [证书] [私钥]
  sbctl cert delete [标识] [--yes]
  sbctl cert renew [标识]
  sbctl cert renew-auto              检查并续期所有自动证书
  sbctl cert cloudflare              管理 Cloudflare DNS 邮箱 / Global API Key

  sbctl backup [文件.tar.gz]
  sbctl restore [文件.tar.gz]
  sbctl bbr
  sbctl diagnose
  sbctl version

证书说明:
  - 域名支持 Cloudflare DNS 自动验证/续期、HTTP 自动验证/续期、DNS 手动 TXT 验证。
  - Cloudflare 使用账号邮箱 + Global API Key，凭据文件权限为 600。
  - DNS 手动验证证书不会被标记为自动续期。
  - 公网 IP 证书使用 Certbot 5.4+ short-lived profile + HTTP 验证。
  - Certbot 使用 /opt/sbctl/certbot 独立环境，不污染系统 Certbot。

支持入站: AnyTLS、VLESS、Hysteria2、Trojan、SOCKS5、HTTP、Mixed
出站: SOCKS5/HTTP 代理、本地出口
EOF_HELP
}

dispatch() {
  local cmd=${1:-menu}; shift || true
  case $cmd in
    cert)
      case ${1:-list} in
        cloudflare) cloudflare_credentials_menu;;
        *) _sbctl_cf_base_dispatch cert "$@";;
      esac
      ;;
    help|-h|--help) show_help;;
    *) _sbctl_cf_base_dispatch "$cmd" "$@";;
  esac
}
