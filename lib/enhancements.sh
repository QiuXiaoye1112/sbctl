# UI/CLI extensions for the certificate and uninstall lifecycle.

# Preserve selected original functions so the wrappers below only add ownership bookkeeping.
eval "$(declare -f dispatch | sed '1s/^dispatch[[:space:]]*()/_sbctl_base_dispatch ()/')"
eval "$(declare -f install_quick_command | sed '1s/^install_quick_command[[:space:]]*()/_sbctl_base_install_quick_command ()/')"
eval "$(declare -f create_service_definition | sed '1s/^create_service_definition[[:space:]]*()/_sbctl_base_create_service_definition ()/')"
eval "$(declare -f backup_all | sed '1s/^backup_all[[:space:]]*()/_sbctl_base_backup_all ()/')"
eval "$(declare -f restore_backup | sed '1s/^restore_backup[[:space:]]*()/_sbctl_base_restore_backup ()/')"
eval "$(declare -f delete_certificate | sed '1s/^delete_certificate[[:space:]]*()/_sbctl_base_delete_certificate ()/')"

install_quick_command() {
  _sbctl_base_install_quick_command "$@"
  meta_resource_register quickCommand "$QUICK_COMMAND"
  meta_resource_register quickSymlink "$QUICK_SYMLINK"
  [[ $LIB_DIR != /usr/local/lib/sbctl ]] || meta_resource_register libDir "$LIB_DIR"
}

create_service_definition() {
  _sbctl_base_create_service_definition "$@"
  meta_resource_register dataDir "$DATA_DIR"
}

backup_all() {
  _sbctl_base_backup_all "$@"
  meta_resource_register backupDir "$BACKUP_DIR"
  info "提示：备份包含配置、metadata 和证书副本，不包含 Certbot 账户/lineage 数据。"
}

restore_backup() {
  _sbctl_base_restore_backup "$@" || return $?
  local id source auto_renew cert_name warned=0
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    source=$(meta_cert_get_field "$id" source)
    auto_renew=$(meta_cert_get_field "$id" autoRenew)
    [[ $source == letsencrypt && $auto_renew == true ]] || continue
    cert_name=$(meta_cert_get_field "$id" certName)
    if [[ -z $cert_name || ! -d $CERTBOT_CONFIG_DIR/live/$cert_name ]]; then
      warn "证书 ${id}: 副本已恢复，但 Certbot lineage 缺失，无法自动续期；请重新签发。"
      ((warned+=1))
    fi
  done < <(meta_cert_list)
  ((warned == 0)) || warn "共 ${warned} 张自动证书缺少 Certbot 续期数据。"
}

_disable_renewal_job_if_unused() {
  local remaining
  remaining=$(meta_cert_auto_renew_certs | head -1 || true)
  [[ -z $remaining ]] || return 0
  case $(init_system) in
    systemd)
      systemctl disable --now sbctl-certbot-renew.timer >/dev/null 2>&1 || true
      systemctl stop sbctl-certbot-renew.service >/dev/null 2>&1 || true
      rm -f "${SYSTEMD_UNIT_DIR}/sbctl-certbot-renew.service" "${SYSTEMD_UNIT_DIR}/sbctl-certbot-renew.timer"
      systemctl daemon-reload >/dev/null 2>&1 || true
      ;;
    openrc) rm -f /etc/periodic/daily/sbctl-certbot-renew;;
  esac
}

delete_certificate() {
  local rc=0
  _sbctl_base_delete_certificate "$@" || rc=$?
  ((rc == 0)) && _disable_renewal_job_if_unused
  return "$rc"
}

certificate_menu() {
  local choice
  while true; do
    clear_screen; heading "TLS 证书"
    printf '托管证书: %s\n\n' "$(managed_certificate_count)"
    printf "1) Let's Encrypt 签发\n2) 导入已有证书\n3) 查看托管证书\n4) 删除托管证书\n5) 立即检查/续期自动证书\n0) 返回\n"
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action issue_certificate; pause;;
      2) run_menu_action import_certificate; pause;;
      3) run_menu_action list_certificates; pause;;
      4) run_menu_action delete_certificate; pause;;
      5) run_menu_action renew_managed_certificates; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

uninstall_menu() {
  local choice
  while true; do
    clear_screen; heading "卸载"
    printf '1) 卸载程序 — 仅删除 sing-box 核心，保留配置/证书/sbctl\n'
    printf '2) 完全卸载 — 删除 sing-box/sbctl/配置/证书，保留备份\n'
    printf '3) 彻底删除 — 清除全部 sbctl 数据和备份\n'
    printf '0) 返回\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action uninstall_sing_box 0; pause;;
      2) run_menu_action uninstall_sing_box 1; return;;
      3) run_menu_action uninstall_sing_box 2; return;;
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

  sbctl backup [文件.tar.gz]
  sbctl restore [文件.tar.gz]
  sbctl bbr
  sbctl diagnose
  sbctl version

证书说明:
  - 域名支持 HTTP 自动验证/续期，或 DNS 手动 TXT 验证。
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
    uninstall)
      case ${1-} in
        "") uninstall_sing_box 0;;
        --purge) uninstall_sing_box 1;;
        --erase) uninstall_sing_box 2;;
        *) die "未知卸载选项：${1}";;
      esac
      ;;
    cert)
      case ${1:-list} in
        renew-auto) renew_managed_certificates;;
        renew) renew_certificate_command "${2-}";;
        delete|remove) delete_certificate "${2-}" "$([[ ${3-} == --yes ]] && printf 1 || printf 0)";;
        *) _sbctl_base_dispatch cert "$@";;
      esac
      ;;
    help|-h|--help) show_help;;
    *) _sbctl_base_dispatch "$cmd" "$@";;
  esac
}
