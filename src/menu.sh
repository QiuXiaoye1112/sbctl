# shellcheck shell=bash
# sbctl menus — canonical interactive UI, dispatch, and help.
# All menus are defined exactly once. No overrides.

# ---- inbound detail menu (from layout.sh — with user_count and protocol-specific options) ----
manage_inbound_menu() {
  local tag=$1 choice row
  while inbound_exists "$tag"; do
    clear_screen
    # Single-jq: fetch type, port, security, user_count in one call
    row=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|[.type,(.listen_port|tostring),(if .tls.reality.enabled==true then "reality" elif .tls.enabled==true then "tls" else "none" end),((.users//[])|length|tostring)]|@tsv' "$CONFIG_FILE")
    IFS=$'\t' read -r type port security user_count <<<"$row"
    heading "入站 · ${tag}"
    printf '协议: %s  |  端口: %s  |  安全: %s\n\n' "$type" "$port" "$security"

    case $type in
      anytls|vless|trojan|hysteria2)
        printf '1) 分享信息\n2) 用户管理\n3) 修改入站信息\n4) 查看 JSON\n0) 返回列表\n'
        read -r -p "请选择: " choice || { echo; return; }
        case $choice in
          1) run_menu_action print_share "$tag"; pause;;
          2) client_menu "$tag";;
          3) modify_inbound_menu "$tag";;
          4) run_menu_action show_inbound "$tag"; pause;;
          0) return;; *) warn "无效选项。"; pause;;
        esac
        ;;
      socks|http)
        if ((user_count > 0)); then
          printf '1) 客户端配置\n2) 用户管理\n3) 修改入站信息\n4) 查看 JSON\n0) 返回列表\n'
          read -r -p "请选择: " choice || { echo; return; }
          case $choice in
            1) run_menu_action print_share "$tag"; pause;;
            2) client_menu "$tag";;
            3) modify_inbound_menu "$tag";;
            4) run_menu_action show_inbound "$tag"; pause;;
            0) return;; *) warn "无效选项。"; pause;;
          esac
        else
          printf '1) 客户端配置\n2) 修改入站信息\n3) 查看 JSON\n0) 返回列表\n'
          read -r -p "请选择: " choice || { echo; return; }
          case $choice in
            1) run_menu_action print_share "$tag"; pause;;
            2) modify_inbound_menu "$tag";;
            3) run_menu_action show_inbound "$tag"; pause;;
            0) return;; *) warn "无效选项。"; pause;;
          esac
        fi
        ;;
      *) warn "不支持的入站协议：${type}"; return;;
    esac
  done
}

# ---- modify inbound menu (from hy2_hop.sh — adds port hopping for hysteria2) ----
modify_inbound_menu() {
  local tag=$1 choice type
  while inbound_exists "$tag"; do
    clear_screen
    type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
    heading "修改入站信息 · ${tag}"
    if [[ $type == hysteria2 ]]; then
      printf '1) 修改入站名称\n2) 修改地址和端口\n3) 修改安全方式 / 证书\n4) 端口跳跃\n0) 返回\n'
    else
      printf '1) 修改入站名称\n2) 修改地址和端口\n3) 修改安全方式 / 证书\n0) 返回\n'
    fi
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action rename_inbound "$tag"; pause; inbound_exists "$tag" || return 0;;
      2) run_menu_action modify_inbound_basic "$tag"; pause;;
      3) run_menu_action modify_inbound_security "$tag"; pause;;
      4) [[ $type == hysteria2 ]] && { run_menu_action hy2_hop_configure "$tag"; pause; } || { warn "无效选项。"; pause; };;
      0) return;;
      *) warn "无效选项。"; pause;;
    esac
  done
}

inbound_menu() {
  ensure_config  # once at entry, not on every redraw
  local choice tag
  while true; do
    clear_screen
    heading "入站管理"
    list_inbounds
    printf '\n完整配置: %s\n\n' "$CONFIG_FILE"
    printf '1) 新增入站\n2) 管理已有入站\n3) 订阅链接\n4) 删除入站\n0) 返回\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action add_inbound; pause;;
      2) select_inbound tag && manage_inbound_menu "$tag";;
      3) run_menu_action print_all_share; pause;;
      4) run_menu_action delete_inbound; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

client_menu() {
  ensure_config  # once at entry
  local tag=$1 choice
  while inbound_exists "$tag"; do
    clear_screen; heading "用户管理 · ${tag}"; list_clients "$tag"
    printf '\n1) 添加用户\n2) 重命名用户\n3) 更换 UUID/密码\n4) 删除用户\n0) 返回\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action add_client "$tag"; pause;;
      2) run_menu_action rename_client "$tag"; pause;;
      3) run_menu_action rotate_client_credential "$tag"; pause;;
      4) run_menu_action delete_client "$tag"; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

outbound_menu() {
  ensure_config  # once at entry
  local choice
  while true; do
    clear_screen
    heading "出站管理"
    list_outbound_overview
    printf '\n1) 选择入站设置出站\n2) 添加 SOCKS5/HTTP 出站\n3) 删除出站\n0) 返回\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action assign_outbound; pause;;
      2) run_menu_action add_outbound; pause;;
      3) run_menu_action delete_outbound; pause;;
      0) return;;
      *) warn "无效选项。"; pause;;
    esac
  done
}

# ---- certificate menu (from cloudflare.sh — adds Cloudflare credentials option) ----
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

toggle_service_running() {
  if service_is_active; then service_action stop; else service_action start; fi
}

toggle_service_startup() {
  if service_is_enabled; then service_disable; info "开机自启已关闭；当前运行状态未改变。"; else service_enable; info "开机自启已开启。"; fi
}

service_menu() {
  local choice svc_summary boot_summary ver_summary
  while true; do
    clear_screen; heading "服务管理"
    # Single _service_summary_all call, parse with read — no repeated awk/systemctl
    read -r svc_summary boot_summary ver_summary <<< "$(_service_summary_all)"
    printf '状态: %s  |  开机自启: %s  |  sing-box: %s\n\n' "$svc_summary" "$boot_summary" "$ver_summary"
    printf '1) 启动/停止\n2) 重启服务\n3) 开关开机自启\n4) 查看日志\n5) 安装/更新/修复 sing-box\n0) 返回\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action toggle_service_running; pause;;
      2) run_menu_action service_action restart; pause;;
      3) run_menu_action toggle_service_startup; pause;;
      4) run_menu_action service_logs 100; pause;;
      5) run_menu_action install_or_update_sing_box; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

system_menu() {
  local choice
  while true; do
    clear_screen; heading "系统工具"
    printf 'BBR: %s\n\n' "$(bbr_state_summary)"
    printf '1) BBR 开启/关闭\n2) 系统诊断\n3) 修复快捷命令\n0) 返回\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action toggle_bbr; pause;;
      2) run_menu_action system_diagnostics; pause;;
      3) run_menu_action repair_quick_command; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

# ---- uninstall menu (from enhancements.sh — three-level model) ----
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

show_main_inbounds() {
  heading "当前入站"
  list_inbounds
  printf '\n'
}

main_menu() {
  ensure_config 2>/dev/null || true
  local choice
  while true; do
    clear_screen
    printf '%ssbctl · sing-box Linux 管理器%s  v%s\n' "$C_BOLD$C_BLUE" "$C_RESET" "$SBCTL_VERSION"
    node_summary
    show_main_inbounds
    printf '1) 入站管理\n2) 出站管理\n3) TLS 证书\n4) 服务管理\n5) 系统工具\n6) 卸载\n0) 退出\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) inbound_menu;; 2) outbound_menu;; 3) certificate_menu;; 4) service_menu;;
      5) system_menu;; 6) uninstall_menu;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

# ---- canonical show_help (merged from all modules) ----
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

  sbctl inbound list                 列出入站
  sbctl inbound add                  新增入站
  sbctl inbound show <标签>          查看入站 JSON
  sbctl inbound rename <旧标签> <新标签>
  sbctl inbound modify [标签]        修改监听地址/端口
  sbctl inbound security [标签]      修改 TLS/REALITY
  sbctl inbound delete [标签] [--yes]

  sbctl outbound list
  sbctl outbound add
  sbctl outbound assign [入站] [出站标签|direct]
  sbctl outbound delete [出站标签]

  sbctl client list [标签]
  sbctl client add [标签]
  sbctl client rename [标签] [旧名称] [新名称]
  sbctl client rotate [标签] [用户]
  sbctl client delete [标签] [用户]

  sbctl link [标签] [用户]           输出分享信息/客户端 JSON
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
  sbctl bbr                           BBR 开启/关闭
  sbctl diagnose
  sbctl version

证书说明:
  - 域名支持 Cloudflare DNS 自动验证/续期、HTTP 自动验证/续期、DNS 手动 TXT 验证。
  - Cloudflare 使用账号邮箱 + Global API Key，凭据文件权限为 600。
  - DNS 手动验证证书不会被标记为自动续期。
  - 公网 IP 证书使用 Certbot 5.4+ short-lived profile + HTTP 验证。
  - Certbot 使用 /opt/sbctl/certbot 独立环境，不污染系统 Certbot。

支持入站: AnyTLS、VLESS、Hysteria2、Trojan、SOCKS5、HTTP
出站: SOCKS5/HTTP 代理、本地出口
EOF_HELP
}

# ---- canonical dispatch (merged from all modules) ----
dispatch() {
  local cmd=${1:-menu}; shift || true
  case $cmd in
    menu) main_menu;;
    help|-h|--help) show_help;;
    version|-v|--version) printf 'sbctl %s\n' "$SBCTL_VERSION";;
    install|update|upgrade) install_or_update_sing_box "${1-}";;
    uninstall)
      case ${1-} in
        "") uninstall_sing_box 0;;
        --purge) uninstall_sing_box 1;;
        --erase) uninstall_sing_box 2;;
        *) die "未知卸载选项：${1}";;
      esac
      ;;
    status) show_status;;
    start|stop|restart|enable|disable) service_action "$cmd";;
    logs) service_logs "${1:-100}";;
    inbound)
      case ${1:-list} in
        list) ensure_config; list_inbounds;;
        add) add_inbound;;
        show) ensure_config; show_inbound "${2:?请提供标签}";;
        rename) rename_inbound "${2-}" "${3-}";;
        modify|edit) modify_inbound_basic "${2-}";;
        security|tls) modify_inbound_security "${2-}";;
        delete|remove) delete_inbound "${2-}" "$([[ ${3-} == --yes ]] && printf 1 || printf 0)";;
        *) die "未知 inbound 子命令：${1}";;
      esac
      ;;
    outbound)
      case ${1:-list} in
        list) list_outbound_overview;;
        add) add_outbound;;
        assign|set) assign_outbound "${2-}" "${3-}";;
        delete|remove) delete_outbound "${2-}";;
        *) die "未知 outbound 子命令：${1}";;
      esac
      ;;
    client)
      case ${1:-list} in
        list) list_clients "${2-}";;
        add) add_client "${2-}";;
        rename) rename_client "${2-}" "${3-}" "${4-}";;
        rotate|reset) rotate_client_credential "${2-}" "${3-}";;
        delete|remove) delete_client "${2-}" "${3-}";;
        *) die "未知 client 子命令：${1}";;
      esac
      ;;
    link|share) print_share "${1-}" "${2-}";;
    config)
      case ${1:-check} in
        check|test) check_config;;
        show) ensure_config; jq . "$CONFIG_FILE";;
        edit) edit_config;;
        *) die "未知 config 子命令。";;
      esac
      ;;
    cert)
      case ${1:-list} in
        list) list_certificates;;
        issue) issue_certificate "${2-}" "${3-}";;
        import) import_certificate "${2-}" "${3-}" "${4-}";;
        delete|remove) delete_certificate "${2-}" "$([[ ${3-} == --yes ]] && printf 1 || printf 0)";;
        renew-auto) renew_managed_certificates;;
        renew) renew_certificate_command "${2-}";;
        cloudflare) cloudflare_credentials_menu;;
        *) die "未知 cert 子命令。";;
      esac
      ;;
    backup) backup_all "${1-}";;
    restore) restore_backup "${1-}";;
    bbr) toggle_bbr;;
    diagnose|doctor) system_diagnostics;;
    quick-command) repair_quick_command;;
    internal-hy2-hop-restore) internal_hy2_hop_restore;;
    internal-hy2-hop-clear) internal_hy2_hop_clear;;
    *) error "未知命令：$cmd"; show_help; return 2;;
  esac
}
