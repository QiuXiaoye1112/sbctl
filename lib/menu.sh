inbound_menu() {
  local choice tag
  while true; do
    clear_screen; heading "入站管理"; list_inbounds
    printf '\n1) 新增入站\n2) 查看入站 JSON\n3) 修改地址/端口\n4) 用户管理\n5) 分享信息\n6) 删除入站\n0) 返回\n'
    read -r -p "请选择: " choice
    case $choice in
      1) run_menu_action add_inbound; pause;;
      2) select_inbound tag && run_menu_action show_inbound "$tag"; pause;;
      3) select_inbound tag && run_menu_action modify_inbound_basic "$tag"; pause;;
      4) select_inbound tag && client_menu "$tag";;
      5) select_inbound tag && run_menu_action print_share "$tag" ""; pause;;
      6) run_menu_action delete_inbound; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

client_menu() {
  local tag=$1 choice
  while inbound_exists "$tag"; do
    clear_screen; heading "用户管理 · ${tag}"; list_clients "$tag"
    printf '\n1) 添加用户\n2) 更换 UUID/密码\n3) 删除用户\n0) 返回\n'
    read -r -p "请选择: " choice
    case $choice in
      1) run_menu_action add_client "$tag"; pause;;
      2) run_menu_action rotate_client_credential "$tag"; pause;;
      3) run_menu_action delete_client "$tag"; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

certificate_menu() {
  local choice
  while true; do
    clear_screen; heading "TLS 证书"
    printf '托管证书: %s\n\n' "$(managed_certificate_count)"
    printf '1) Let\x27s Encrypt 自动签发\n2) 导入证书\n3) 查看证书\n4) 删除证书\n0) 返回\n'
    read -r -p "请选择: " choice
    case $choice in
      1) run_menu_action issue_certificate; pause;; 2) run_menu_action import_certificate; pause;;
      3) run_menu_action list_certificates; pause;; 4) run_menu_action delete_certificate; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

service_menu() {
  local choice
  while true; do
    clear_screen; heading "服务管理"; show_status
    printf '\n1) 启动\n2) 停止\n3) 重启\n4) 开启自启\n5) 关闭自启\n6) 查看日志\n7) 安装/更新 sing-box\n0) 返回\n'
    read -r -p "请选择: " choice
    case $choice in
      1) run_menu_action service_action start; pause;; 2) run_menu_action service_action stop; pause;;
      3) run_menu_action service_action restart; pause;; 4) run_menu_action service_action enable; pause;;
      5) run_menu_action service_action disable; pause;; 6) run_menu_action service_logs 100; pause;;
      7) run_menu_action install_or_update_sing_box; pause;; 0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

backup_menu() {
  local choice
  while true; do
    clear_screen; heading "配置与备份"
    printf '1) 检查配置\n2) 编辑完整配置\n3) 创建备份\n4) 恢复备份\n0) 返回\n'
    read -r -p "请选择: " choice
    case $choice in
      1) run_menu_action check_config; pause;; 2) run_menu_action edit_config; pause;;
      3) run_menu_action backup_all; pause;; 4) run_menu_action restore_backup; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

uninstall_menu() {
  local choice
  while true; do
    clear_screen; heading "卸载"
    printf '1) 卸载 sing-box，保留配置\n2) 完全卸载（同时删除配置、证书、元数据和 sbctl）\n0) 返回\n'
    read -r -p "请选择: " choice
    case $choice in
      1)
        run_menu_action uninstall_sing_box 0
        pause
        return
        ;;
      2)
        run_menu_action uninstall_sing_box 1
        [[ -e $QUICK_COMMAND || -d $CONFIG_DIR ]] && pause
        return
        ;;
      0) return;;
      *) warn "无效选项。"; pause;;
    esac
  done
}

main_menu() {
  ensure_config 2>/dev/null || true
  local choice
  while true; do
    clear_screen
    printf '%ssbctl · sing-box Linux 管理器%s  v%s\n' "$C_BOLD$C_BLUE" "$C_RESET" "$SBCTL_VERSION"
    node_summary
    printf '\n1) 入站管理\n2) TLS 证书\n3) 服务管理\n4) 配置与备份\n5) 查看状态\n6) 卸载\n0) 退出\n'
    read -r -p "请选择: " choice
    case $choice in
      1) inbound_menu;; 2) certificate_menu;; 3) service_menu;; 4) backup_menu;;
      5) run_menu_action show_status; pause;;
      6) uninstall_menu; [[ -e $QUICK_COMMAND || -d $CONFIG_DIR ]] || return;;
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
  sbctl uninstall                    卸载 sing-box，保留配置和 sbctl
  sbctl uninstall --purge            完全卸载并删除配置、证书、元数据和 sbctl
  sbctl status                       查看状态
  sbctl start|stop|restart           服务控制
  sbctl enable|disable               开关开机自启
  sbctl logs [行数]                  查看日志

  sbctl inbound list                 列出入站
  sbctl inbound add                  新增入站
  sbctl inbound show <标签>          查看入站 JSON
  sbctl inbound modify [标签]        修改监听地址/端口
  sbctl inbound delete [标签] [--yes]

  sbctl client list [标签]
  sbctl client add [标签]
  sbctl client rotate [标签] [用户]
  sbctl client delete [标签] [用户]

  sbctl link [标签] [用户]           输出分享信息/客户端 JSON
  sbctl config check|show|edit
  sbctl cert list
  sbctl cert issue [域名] [邮箱]
  sbctl cert import [标识] [证书] [私钥]
  sbctl cert delete [标识]
  sbctl backup [文件.tar.gz]
  sbctl restore [文件.tar.gz]
  sbctl version

首批支持入站:
  AnyTLS、VLESS、Hysteria2、Trojan、SOCKS5、HTTP、Mixed

安全层:
  AnyTLS/VLESS/Trojan: REALITY 或证书 TLS
  Hysteria2: 证书 TLS
EOF_HELP
}

dispatch() {
  local cmd=${1:-menu}; shift || true
  case $cmd in
    menu) main_menu;; help|-h|--help) show_help;; version|-v|--version) printf 'sbctl %s\n' "$SBCTL_VERSION";;
    install|update|upgrade) install_or_update_sing_box "${1-}";;
    uninstall) [[ ${1-} == --purge ]] && uninstall_sing_box 1 || uninstall_sing_box 0;;
    status) show_status;; start|stop|restart|enable|disable) service_action "$cmd";; logs) service_logs "${1:-100}";;
    inbound)
      case ${1:-list} in
        list) ensure_config; list_inbounds;; add) add_inbound;; show) ensure_config; show_inbound "${2:?请提供标签}";;
        modify|edit) modify_inbound_basic "${2-}";; delete|remove) delete_inbound "${2-}" "$([[ ${3-} == --yes ]] && printf 1 || printf 0)";;
        *) die "未知 inbound 子命令：${1}";; esac;;
    client)
      case ${1:-list} in
        list) list_clients "${2-}";; add) add_client "${2-}";; rotate|reset) rotate_client_credential "${2-}" "${3-}";;
        delete|remove) delete_client "${2-}" "${3-}";; *) die "未知 client 子命令：${1}";; esac;;
    link|share) print_share "${1-}" "${2-}";;
    config)
      case ${1:-check} in check|test) check_config;; show) ensure_config; jq . "$CONFIG_FILE";; edit) edit_config;; *) die "未知 config 子命令。";; esac;;
    cert)
      case ${1:-list} in list) list_certificates;; issue) issue_certificate "${2-}" "${3-}";; import) import_certificate "${2-}" "${3-}" "${4-}";; delete|remove) delete_certificate "${2-}";; *) die "未知 cert 子命令。";; esac;;
    backup) backup_all "${1-}";; restore) restore_backup "${1-}";;
    *) error "未知命令：$cmd"; show_help; return 2;;
  esac
}
