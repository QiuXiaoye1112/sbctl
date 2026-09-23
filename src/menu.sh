# shellcheck shell=bash
# sbctl menus — canonical interactive UI, dispatch, and help.
# All menus are defined exactly once.

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

domain_rule_detail_menu() {
  local tag=$1 choice template outbound has_binding=0
  while inbound_exists "$tag"; do
    clear_screen
    heading "域名分流 · ${tag}"
    printf '模板：\n'
    has_binding=0
    while IFS=$'\t' read -r template outbound; do
      [[ -n $template ]] || continue
      printf '  %s → %s\n' "$template" "$outbound"
      has_binding=1
    done < <(list_inbound_template_bindings "$tag")
    ((has_binding)) || printf '  无\n'
    printf '\n'
    list_domain_rules "$tag" --menu
    printf '\n1) 管理模板\n2) 添加规则\n3) 删除规则\n0) 返回\n'
    read -r -p '请选择: ' choice || return
    case $choice in
      1) inbound_template_manage_menu "$tag";;
      2) if run_menu_action add_domain_rule "$tag" "" "" "" --prompt; then pause; fi;;
      3) if run_menu_action delete_domain_rule "$tag" "" "" --direct-only; then pause; fi;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

domain_rule_inbound_templates() {
  local tag=$1 template outbound summary=''
  while IFS=$'\t' read -r template outbound; do
    [[ -n $template ]] || continue
    [[ -n $summary ]] && summary+=', '
    summary+="$template"
  done < <(list_inbound_template_bindings "$tag")
  printf '%s' "${summary:-无}"
}

domain_rule_inbound_count() {
  local tag=$1
  jq -r --arg tag "$tag" "$(_sbctl_managed_domain_rule_filter)
    [.route.rules[]? | select(sbctl_managed_domain_rule and .inbound==[\$tag])] | length" "$CONFIG_FILE"
}

domain_rule_menu() {
  ensure_config
  local choice tag number
  local -a tags=()
  while true; do
    clear_screen
    heading '域名分流'
    printf '入站列表\n\n'
    tags=()
    while IFS= read -r tag; do [[ -n $tag ]] && tags+=("$tag"); done < <(jq -r '.inbounds[].tag' "$CONFIG_FILE")
    if ((${#tags[@]} == 0)); then
      info '没有可选入站。'
      pause
      return 0
    fi
    for ((number=0; number<${#tags[@]}; number++)); do
      tag=${tags[$number]}
      printf '%d) %s\n' "$((number+1))" "$tag"
      printf '   模板：%s\n' "$(domain_rule_inbound_templates "$tag")"
      printf '   域名规则：%s 条\n\n' "$(domain_rule_inbound_count "$tag")"
    done
    printf '操作：\n  [%d] 管理模板\n  [0] 返回\n' "$(( ${#tags[@]} + 1 ))"
    read -r -p '请选择: ' choice || return
    case $choice in
      0) return;;
      ''|*[!0-9]*) warn '无效选项。'; pause;;
      *)
        if ((choice == ${#tags[@]} + 1)); then template_library_menu
        elif ((choice >= 1 && choice <= ${#tags[@]})); then domain_rule_detail_menu "${tags[$((choice-1))]}"
        else warn '无效选项。'; pause; fi
        ;;
    esac
  done
}

select_inbound_template() {
  local inbound=$1 __var=$2 answer template_name template_outbound
  local -a names=()
  while IFS=$'\t' read -r template_name template_outbound; do
    [[ -n $template_name ]] && names+=("$template_name")
  done < <(list_inbound_template_bindings "$inbound")
  ((${#names[@]})) || { warn "当前入站还没有应用模板。"; return 1; }
  choose answer "选择模板" "${names[@]}" || return 1
  printf -v "$__var" '%s' "${names[$((answer-1))]}"
}

inbound_template_manage_menu() {
  local inbound=$1 choice name outbound
  while inbound_exists "$inbound"; do
    clear_screen
    heading "入站模板 · ${inbound}"
    printf '已应用模板：\n'
    while IFS=$'\t' read -r name outbound; do [[ -n $name ]] && printf '  %s → %s\n' "$name" "$outbound"; done \
      < <(list_inbound_template_bindings "$inbound")
    printf '\n1) 添加模板\n2) 移除模板\n3) 修改出站\n0) 返回\n'
    read -r -p '请选择: ' choice || return
    case $choice in
      1) if apply_domain_template_menu "$inbound"; then pause; fi;;
      2)
        select_inbound_template "$inbound" name || continue
        confirm "从入站 ${inbound} 移除模板 ${name}？" N || continue
        run_menu_action remove_domain_template "$inbound" "$name"; pause;;
      3)
        select_inbound_template "$inbound" name || continue
        select_outbound outbound 1 || continue
        run_menu_action update_domain_template_outbound "$inbound" "$name" "$outbound"; pause;;
      0) return;; *) warn '无效选项。'; pause;;
    esac
  done
}

select_domain_template() {
  local __var=$1 answer template_name
  local -a names=()
  while IFS=$'\t' read -r template_name _ _; do [[ -n $template_name ]] && names+=("$template_name"); done \
    < <(list_domain_templates)
  ((${#names[@]})) || { warn "还没有模板。"; return 1; }
  choose answer "选择模板" "${names[@]}" || return 1
  printf -v "$__var" '%s' "${names[$((answer-1))]}"
}

delete_domain_template_domains_menu() {
  local name=$1 match=$2 selection token idx valid type_label choice joined domain
  local -a domains=() selected=() tokens=()
  [[ $match == suffix ]] && type_label=子域名 || type_label=精确域名
  while IFS= read -r domain; do [[ -n $domain ]] && domains+=("$domain"); done < <(
    jq -r --arg name "$name" --arg match "$match" '.domainTemplates.templates[]? |
      select(.name==$name) | .[$match][]? // empty' "$META_FILE")
  ((${#domains[@]})) || { warn "当前模板没有${type_label}。"; return 1; }
  printf '\n%s：\n\n' "$type_label"
  for ((idx=0; idx<${#domains[@]}; idx++)); do printf '%d) %s\n' "$((idx+1))" "${domains[$idx]}"; done
  while true; do
    read -r -p '请选择要删除的域名（支持 1,3,2）: ' selection || return 1
    selection=$(printf '%s' "$selection" | tr -d '[:space:]'); selected=()
    [[ -n $selection ]] || return 1
    IFS=',' read -r -a tokens <<<"$selection"; valid=1
    for token in "${tokens[@]}"; do
      if [[ ! $token =~ ^[0-9]+$ ]] || ((10#$token < 1 || 10#$token > ${#domains[@]})); then valid=0; break; fi
      idx=$((10#$token))
      if ((${#selected[@]})); then
        for choice in "${selected[@]}"; do ((choice != idx)) || { valid=0; break 2; }; done
      fi
      selected+=("$idx")
    done
    ((valid)) && ((${#selected[@]})) && break
    warn "请输入有效且不重复的序号，例如 1,3,2。"
  done
  printf '\n将删除：\n'
  for idx in "${selected[@]}"; do printf -- '- %s\n' "${domains[$((idx-1))]}"; done
  confirm "确认从模板 ${name} 删除这些域名？" N || return 1
  joined=''
  for idx in "${selected[@]}"; do [[ -n $joined ]] && joined+=','; joined+="${domains[$((idx-1))]}"; done
  run_menu_action delete_domain_template_domains "$name" "$match" "$joined"
}

template_manage_menu() {
  local name=$1 choice type domains match
  while domain_template_exists "$name"; do
    clear_screen; heading "模板 · ${name}"
    printf '精确域名：\n'
    jq -r --arg name "$name" '.domainTemplates.templates[]? | select(.name==$name) | .exact[]? // empty | "  "+.' "$META_FILE"
    printf '子域名：\n'
    jq -r --arg name "$name" '.domainTemplates.templates[]? | select(.name==$name) | .suffix[]? // empty | "  "+.' "$META_FILE"
    printf '\n1) 添加域名\n2) 删除域名\n0) 返回\n'
    read -r -p '请选择: ' choice || return
    case $choice in
      1)
        choose type "域名类型" "精确域名" "域名及所有子域名" || continue
        [[ $type == 1 ]] && match=exact || match=suffix
        prompt_value domains "域名（多个请用英文逗号分隔）" || continue
        run_menu_action add_domain_template_domains "$name" "$match" "$domains"; pause;;
      2)
        choose type "域名类型" "精确域名" "域名及所有子域名" || continue
        [[ $type == 1 ]] && match=exact || match=suffix
        if delete_domain_template_domains_menu "$name" "$match"; then pause; fi;;
      0) return;; *) warn '无效选项。'; pause;;
    esac
  done
}

template_library_menu() {
  local choice name exact suffix number
  local -a names=()
  while true; do
    clear_screen; heading '模板库'; names=(); number=0
    while IFS=$'\t' read -r name exact suffix; do
      [[ -n $name ]] || continue
      names+=("$name"); ((number+=1))
      printf '%s) %-16s 精确 %s 个，子域名 %s 个\n' "$number" "$name" "$exact" "$suffix"
    done < <(list_domain_templates)
    printf '\n%s) 新建模板\n0) 返回\n' "$((number+1))"
    read -r -p '请选择: ' choice || return
    case $choice in
      0) return;; ''|*[!0-9]*) warn '无效选项。'; pause;;
      *)
        if ((choice == ${#names[@]} + 1)); then run_menu_action create_domain_template; pause
        elif ((choice >= 1 && choice <= ${#names[@]})); then template_manage_menu "${names[$((choice-1))]}"
        else warn '无效选项。'; pause; fi;;
    esac
  done
}

apply_domain_template_menu() {
  local inbound=$1 name outbound
  select_domain_template name || return 1
  select_outbound outbound 1 || return 1
  run_menu_action apply_domain_template "$inbound" "$name" "$outbound"
}

outbound_menu() {
  ensure_config  # once at entry
  local choice
  while true; do
    clear_screen
    heading "出站管理"
    list_outbound_overview
    printf '\n1) 设置入站默认出站\n2) 域名分流\n3) 添加 SOCKS5/HTTP 出站\n4) 查看出站详情\n5) 删除出站\n0) 返回\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action assign_outbound; pause;;
      2) domain_rule_menu;;
      3) run_menu_action add_outbound; pause;;
      4) run_menu_action show_outbound_details; pause;;
      5) run_menu_action delete_outbound; pause;;
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
    printf '1) 启动/停止\n2) 重启服务\n3) 开关开机自启\n4) 查看日志\n5) 安装/更新/修复 sing-box\n6) 系统诊断\n7) 修复快捷命令\n0) 返回\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action toggle_service_running; pause;;
      2) run_menu_action service_action restart; pause;;
      3) run_menu_action toggle_service_startup; pause;;
      4) run_menu_action service_logs 100; pause;;
      5) run_menu_action install_or_update_sing_box; pause;;
      6) run_menu_action system_diagnostics; pause;;
      7) run_menu_action repair_quick_command; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

# ---- three-level uninstall menu ----
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

traffic_menu() {
  local choice
  traffic_is_enabled && run_menu_action traffic_collect
  while true; do
    clear_screen
    traffic_show || true
    printf '\n1) 刷新\n2) 流量限制\n3) 清空指定入站记录\n4) 清空全部流量记录\n'
    if traffic_is_enabled; then printf '5) 停止流量统计\n'; else printf '5) 开启流量统计\n'; fi
    printf '6) 设置月度统计起点\n'
    printf '0) 返回\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action traffic_collect;;
      2) traffic_limit_menu;;
      3) run_menu_action traffic_clear_tag_records; pause;;
      4) run_menu_action traffic_clear_all_records; pause;;
      5)
        if traffic_is_enabled; then run_menu_action traffic_disable; else run_menu_action traffic_enable; fi
        pause
        ;;
      6) run_menu_action traffic_period_set; pause;;
      0) return;;
      *) warn "无效选项。"; pause;;
    esac
  done
}

traffic_limit_menu() {
  local choice
  while true; do
    if traffic_is_enabled; then run_menu_action traffic_collect || true; fi
    clear_screen
    traffic_limits_show || true
    if traffic_limits_are_enabled; then
      printf '操作\n1) 刷新状态\n2) 设置/修改入站额度\n3) 取消入站额度\n4) 关闭流量限制\n0) 返回\n'
    else
      printf '操作\n1) 启用流量限制\n0) 返回\n'
    fi
    read -r -p "请选择: " choice || { echo; return; }
    if traffic_limits_are_enabled; then
      case $choice in
        1) continue;;
        2) run_menu_action traffic_limit_set; pause;;
        3) run_menu_action traffic_limit_remove; pause;;
        4) run_menu_action traffic_limits_disable; pause;;
        0) return 0;;
        *) warn "无效选项。"; pause;;
      esac
    else
      case $choice in
        1) run_menu_action traffic_limits_enable; pause;;
        0) return 0;;
        *) warn "无效选项。"; pause;;
      esac
    fi
  done
}

main_menu() {
  ensure_config 2>/dev/null || true
  local choice
  while true; do
    clear_screen
    printf '%ssbctl · sing-box Linux 管理器%s  v%s\n' "$C_BOLD$C_BLUE" "$C_RESET" "$SBCTL_VERSION"
    node_summary
    show_main_inbounds
    printf '1) 入站管理\n2) 出站管理\n3) TLS 证书\n4) 流量信息\n5) BBR启用/关闭\n6) 服务管理\n7) 卸载\n0) 退出\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) inbound_menu;; 2) outbound_menu;; 3) certificate_menu;; 4) traffic_menu;;
      5) run_menu_action toggle_bbr; pause;; 6) service_menu;; 7) uninstall_menu;;
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
  sbctl traffic                      查看当前月度周期流量
  sbctl traffic period show          查看统一统计起点
  sbctl traffic period set <日> <时:分> 设置统一统计起点
  sbctl traffic enable|disable       开启/停止流量统计
  sbctl traffic limit show|enable|disable
  sbctl traffic limit set <标签> <GB> <重置日>
  sbctl traffic limit remove <标签>

  sbctl inbound list                 列出入站
  sbctl inbound add                  新增入站
  sbctl inbound show <标签>          查看入站 JSON
  sbctl inbound rename <旧标签> <新标签>
  sbctl inbound modify [标签]        修改监听地址/端口
  sbctl inbound security [标签]      修改 TLS/REALITY
  sbctl inbound disable <标签> [--yes] 禁用入站
  sbctl inbound enable <标签> [--yes] 启用入站
  sbctl inbound delete [标签] [--yes]

  sbctl outbound list
  sbctl outbound add
  sbctl outbound assign [入站] [出站标签|direct]
  sbctl outbound delete [出站标签]
  sbctl outbound rule list [入站]
  sbctl outbound rule add <入站> <suffix|exact> <域名[,域名...]> <出站>
  sbctl outbound rule delete [入站] [suffix|exact] [域名]

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
  sbctl bbr                           启用/关闭 BBR（交互式）
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
    traffic)
      case ${1:-show} in
        show) traffic_collect || true; traffic_show "${2-}" "${3-}";;
        enable|start) traffic_enable;;
        disable|stop) traffic_disable;;
        collect|refresh) traffic_collect;;
        period)
          case ${2:-show} in
            show) traffic_period_show;;
            set) traffic_period_set "${3-}" "${4-}";;
            *) die "未知 traffic period 子命令：${2}";;
          esac
          ;;
        reset)
          if [[ ${2-} == --all ]]; then traffic_clear_all_records; else traffic_clear_tag_records "${2-}"; fi
          ;;
        limit)
          case ${2:-show} in
            show) traffic_limits_show;;
            enable|start) traffic_limits_enable;;
            disable|stop) traffic_limits_disable;;
            set) traffic_limit_set "${3-}" "${4-}" "${5-}";;
            remove|delete) traffic_limit_remove "${3-}";;
            *) die "未知 traffic limit 子命令：${2}";;
          esac
          ;;
        [0-9][0-9][0-9][0-9]-*) traffic_collect || true; traffic_show "$1" "${2:-$(traffic_today)}";;
        *) die "未知 traffic 子命令：${1}";;
      esac
      ;;
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
        rule)
          case ${2:-list} in
            list) list_domain_rules "${3-}";;
            add) add_domain_rule "${3-}" "${4-}" "${5-}" "${6-}";;
            delete|remove) delete_domain_rule "${3-}" "${4-}" "${5-}";;
            *) die "未知 outbound rule 子命令：${2}";;
          esac
          ;;
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
    internal-traffic-collect) internal_traffic_collect;;
    internal-traffic-watch) internal_traffic_watch;;
    *) error "未知命令：$cmd"; show_help; return 2;;
  esac
}
