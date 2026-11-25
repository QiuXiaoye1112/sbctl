# shellcheck shell=bash
# sbctl menus — canonical interactive UI, dispatch, and help.
# All menus are defined exactly once.

manage_inbound_menu() {
  local tag=$1 choice row type port security user_count
  while inbound_exists "$tag"; do
    row=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|[.type,(.listen_port|tostring),(if .tls.reality.enabled==true then "reality" elif .tls.enabled==true then "tls" else "none" end),((.users//[])|length|tostring)]|@tsv' "$CONFIG_FILE")
    IFS=$'\t' read -r type port security user_count <<<"$row"
    ui_page "入站 · ${tag}" "主菜单 › 入站管理"
    ui_field "协议 / 安全" "$(protocol_display_name "$type" || printf '%s' "$type") · ${security}"
    ui_field "监听端口" "$port"

    case $type in
      anytls|hysteria2)
        ui_field "用户" "${user_count} 个"
        ui_section "连接与用户"
        ui_option 1 "分享信息"
        ui_option 2 "用户管理"
        ui_section "配置"
        ui_option 3 "修改入站信息"
        if [[ $security == tls ]]; then
          ui_option 4 "证书管理"
          ui_option 5 "查看 JSON"
        else
          ui_option 4 "查看 JSON"
        fi
        ui_footer "返回入站列表"
        read -r -p "  请选择: " choice || { echo; return; }
        case $choice in
          1) run_menu_action print_share "$tag"; pause;;
          2) client_menu "$tag";;
          3) modify_inbound_menu tag;;
          4) if [[ $security == tls ]]; then inbound_certificate_menu "$tag"; else run_menu_action show_inbound "$tag"; pause; fi;;
          5) if [[ $security == tls ]]; then run_menu_action show_inbound "$tag"; else warn "无效选项。"; fi; pause;;
          0) return;; *) warn "无效选项。"; pause;;
        esac
        ;;
      socks|http)
        if ((user_count > 0)); then ui_field "账号认证" "${user_count} 个用户"; else ui_field "账号认证" "无认证"; fi
        ui_section "客户端"
        ui_option 1 "客户端配置"
        if ((user_count > 0)); then
          ui_option 2 "用户管理"
          ui_section "配置"
          ui_option 3 "修改入站信息"
          ui_option 4 "查看 JSON"
          ui_footer "返回入站列表"
          read -r -p "  请选择: " choice || { echo; return; }
          case $choice in
            1) run_menu_action print_share "$tag"; pause;;
            2) client_menu "$tag";;
            3) modify_inbound_menu tag;;
            4) run_menu_action show_inbound "$tag"; pause;;
            0) return;; *) warn "无效选项。"; pause;;
          esac
        else
          ui_section "配置"
          ui_option 2 "修改入站信息"
          ui_option 3 "查看 JSON"
          ui_footer "返回入站列表"
          read -r -p "  请选择: " choice || { echo; return; }
          case $choice in
            1) run_menu_action print_share "$tag"; pause;;
            2) modify_inbound_menu tag;;
            3) run_menu_action show_inbound "$tag"; pause;;
            0) return;; *) warn "无效选项。"; pause;;
          esac
        fi
        ;;
      *) warn "不支持的入站协议：${type}"; return;;
    esac
  done
}

inbound_certificate_menu() {
  local tag=$1 choice row cert key sni
  while inbound_exists "$tag" && jq -e --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.enabled==true and (.tls.reality.enabled!=true)' "$CONFIG_FILE" >/dev/null; do
    row=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|[.tls.certificate_path // "未设置",.tls.key_path // "未设置",.tls.server_name // "未设置"]|@tsv' "$CONFIG_FILE")
    IFS=$'\t' read -r cert key sni <<<"$row"
    ui_page "证书管理 · ${tag}" "主菜单 › 入站管理"
    ui_field "证书文件" "$cert"
    ui_field "私钥文件" "$key"
    ui_field "SNI" "$sni"
    ui_section "证书操作"
    ui_option 1 "更换证书"
    ui_footer "返回入站"
    read -r -p '  请选择: ' choice || { echo; return; }
    case $choice in
      1) run_menu_action modify_inbound_certificate "$tag"; pause;;
      0) return;; *) warn '无效选项。'; pause;;
    esac
  done
}

modify_inbound_menu() {
  local -n current_tag=$1
  local choice type new_tag row up down
  while inbound_exists "$current_tag"; do
    row=$(jq -r --arg tag "$current_tag" '
      .inbounds[] | select(.tag==$tag) | [.type, (.up_mbps // 0), (.down_mbps // 0)] | @tsv
    ' "$CONFIG_FILE")
    IFS=$'\t' read -r type up down <<<"$row"
    ui_page "修改入站信息 · ${current_tag}" "主菜单 › 入站管理"
    if [[ $type == hysteria2 ]]; then
      ui_field "上行 / 下行" "$(hy2_bandwidth_display "$up") / $(hy2_bandwidth_display "$down")"
    fi
    ui_section "基础设置"
    ui_option 1 "修改入站名称"
    ui_option 2 "修改客户端连接地址"
    ui_option 6 "修改监听端口"
    ui_section "安全与传输"
    ui_option 3 "修改安全方式 / 证书"
    if [[ $type == hysteria2 ]]; then
      ui_option 4 "端口跳跃"
      ui_option 5 "修改上下行限速"
    fi
    ui_footer "返回入站"
    read -r -p "  请选择: " choice || { echo; return; }
    case $choice in
      1) prompt_value new_tag "新入站名称" "$current_tag" || continue
         if [[ $new_tag == "$current_tag" ]]; then info "名称未更改。"
         else
           run_menu_action rename_inbound "$current_tag" "$new_tag"
           if ! inbound_exists "$current_tag" && inbound_exists "$new_tag"; then current_tag=$new_tag; fi
         fi
         pause;;
      2) run_menu_action modify_inbound_basic "$current_tag" address; pause;;
      6) run_menu_action modify_inbound_basic "$current_tag" port; pause;;
      3) run_menu_action modify_inbound_security "$current_tag"; pause;;
      4) case $type in hysteria2) run_menu_action hy2_hop_configure "$current_tag";; *) warn "无效选项。";; esac; pause;;
      5) case $type in hysteria2) run_menu_action hy2_modify_bandwidth "$current_tag";; *) warn "无效选项。";; esac; pause;;
      0) return;;
      *) warn "无效选项。"; pause;;
    esac
  done
}

inbound_menu() {
  ensure_config  # once at entry, not on every redraw
  local choice tag
  while true; do
    ui_page "入站管理" "主菜单"
    ui_field "配置文件" "$CONFIG_FILE"
    ui_section "入站列表"
    list_inbounds --menu
    ui_section "入站操作"
    ui_option 1 "新增入站"
    ui_option 2 "管理已有入站"
    ui_option 3 "全部分享信息"
    ui_option 4 "删除入站"
    ui_footer "返回主菜单"
    read -r -p "  请选择: " choice || { echo; return; }
    case $choice in
      1) ui_page "新增入站" "主菜单 › 入站管理"; run_menu_action add_inbound; pause;;
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
    ui_page "用户管理 · ${tag}" "主菜单 › 入站管理"
    list_clients "$tag" --menu
    ui_section "用户操作"
    ui_option 1 "添加用户"
    ui_option 2 "重命名用户"
    ui_option 3 "更换密码"
    ui_option 4 "删除用户"
    ui_footer "返回入站"
    read -r -p "  请选择: " choice || { echo; return; }
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
    ui_page "域名分流 · ${tag}" "主菜单 › 出站管理 › 域名分流"
    ui_section "已应用模板"
    has_binding=0
    while IFS=$'\t' read -r template outbound; do
      [[ -n $template ]] || continue
      printf '  %s → %s\n' "$template" "$outbound"
      has_binding=1
    done < <(list_inbound_template_bindings "$tag")
    ((has_binding)) || printf '  无\n'
    printf '\n'
    list_domain_rules "$tag" --menu
    ui_section "分流操作"
    ui_option 1 "管理模板"
    ui_option 2 "添加规则"
    ui_option 3 "删除规则"
    ui_footer "返回入站列表"
    read -r -p '  请选择: ' choice || return
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
    ui_page "域名分流" "主菜单 › 出站管理"
    ui_section "选择入站"
    tags=()
    while IFS= read -r tag; do [[ -n $tag ]] && tags+=("$tag"); done < <(jq -r '.inbounds[].tag // empty' "$CONFIG_FILE")
    if ((${#tags[@]} == 0)); then
      info '没有可选入站。'
    fi
    for ((number=0; number<${#tags[@]}; number++)); do
      tag=${tags[$number]}
      ui_option "$((number+1))" "$tag"
      printf '       模板 %s · 域名规则 %s 条\n' "$(domain_rule_inbound_templates "$tag")" "$(domain_rule_inbound_count "$tag")"
    done
    ui_section "模板"
    ui_option "$(( ${#tags[@]} + 1 ))" "管理模板"
    ui_footer "返回出站管理"
    read -r -p '  请选择: ' choice || return
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
    ui_page "入站模板 · ${inbound}" "主菜单 › 出站管理 › 域名分流"
    ui_section "已应用模板"
    while IFS=$'\t' read -r name outbound; do [[ -n $name ]] && printf '  %s → %s\n' "$name" "$outbound"; done \
      < <(list_inbound_template_bindings "$inbound")
    ui_section "模板操作"
    ui_option 1 "添加模板"
    ui_option 2 "移除模板"
    ui_option 3 "修改出站"
    ui_footer "返回域名分流"
    read -r -p '  请选择: ' choice || return
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
  ui_section "$type_label"
  for ((idx=0; idx<${#domains[@]}; idx++)); do ui_option "$((idx+1))" "${domains[$idx]}"; done
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
    ui_page "模板 · ${name}" "主菜单 › 出站管理 › 模板库"
    ui_section "精确域名"
    jq -r --arg name "$name" '.domainTemplates.templates[]? | select(.name==$name) | .exact[]? // empty | "  "+.' "$META_FILE"
    ui_section "子域名"
    jq -r --arg name "$name" '.domainTemplates.templates[]? | select(.name==$name) | .suffix[]? // empty | "  "+.' "$META_FILE"
    ui_section "域名操作"
    ui_option 1 "添加域名"
    ui_option 2 "删除域名"
    ui_footer "返回模板库"
    read -r -p '  请选择: ' choice || return
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
    ui_page "模板库" "主菜单 › 出站管理 › 域名分流"
    names=(); number=0
    while IFS=$'\t' read -r name exact suffix; do
      [[ -n $name ]] || continue
      names+=("$name"); ((number+=1))
      ui_option "$number" "$name"
      printf '       精确域名 %s 个 · 子域名 %s 个\n' "$exact" "$suffix"
    done < <(list_domain_templates)
    if ((number == 0)); then printf '  暂无模板。\n'; fi
    ui_section "模板操作"
    ui_option "$((number+1))" "新建模板"
    ui_footer "返回域名分流"
    read -r -p '  请选择: ' choice || return
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
    ui_page "出站管理" "主菜单"
    list_outbound_overview --menu
    ui_section "路由"
    ui_option 1 "设置入站默认出站"
    ui_option 2 "域名分流"
    ui_section "代理出站"
    ui_option 3 "添加 SOCKS5 / HTTP 出站"
    ui_option 4 "查看出站详情"
    ui_option 5 "删除出站"
    ui_footer "返回主菜单"
    read -r -p "  请选择: " choice || { echo; return; }
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

certificate_menu() {
  local choice
  while true; do
    ui_page "TLS 证书" "主菜单"
    ui_field "托管证书" "$(managed_certificate_count) 张"
    ui_section "证书"
    ui_option 1 "Let's Encrypt 签发"
    ui_option 2 "导入已有证书"
    ui_option 3 "查看托管证书"
    ui_option 4 "删除托管证书"
    ui_section "DNS 与续期"
    ui_option 5 "Cloudflare DNS 凭据"
    ui_option 6 "立即检查并续期"
    ui_footer "返回主菜单"
    read -r -p "  请选择: " choice || { echo; return; }
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
  ensure_dependencies service
  service_exists || die "sing-box 服务不存在。"
  if service_is_enabled; then service_disable || return; info "开机自启已关闭；当前服务运行状态未改变。"; else service_enable || return; info "开机自启已开启。"; fi
}

service_menu() {
  local choice svc_summary boot_summary ver_summary
  while true; do
    ui_page "服务管理" "主菜单"
    read -r svc_summary boot_summary ver_summary <<< "$(_service_summary_all)"
    ui_field "服务状态" "$(ui_status "$svc_summary")"
    ui_field "开机自启" "$(ui_status "$boot_summary")"
    ui_field "sing-box" "$ver_summary"
    ui_section "服务操作"
    case $svc_summary in
      运行中) ui_option 1 "停止服务" ;;
      已停止) ui_option 1 "启动服务" ;;
      *) ui_option 1 "启动 / 停止" ;;
    esac
    ui_option 2 "重启服务"
    ui_option 3 "切换开机自启"
    ui_section "维护"
    ui_option 4 "查看日志"
    ui_option 5 "安装 / 更新 sing-box"
    ui_footer "返回主菜单"
    read -r -p "  请选择: " choice || { echo; return; }
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

show_main_inbounds() {
  ui_section "入站概览"
  list_inbounds --menu
}

traffic_menu() {
  local choice
  traffic_is_enabled && run_menu_action traffic_collect
  while true; do
    ui_page "流量信息" "主菜单"
    traffic_show "" "" --menu || true
    ui_section "统计与额度"
    ui_option 1 "刷新流量"
    ui_option 2 "流量限制"
    ui_section "记录与周期"
    ui_option 3 "清空指定入站记录"
    ui_option 4 "清空全部流量记录"
    if traffic_is_enabled; then ui_option 5 "停止流量统计"; else ui_option 5 "开启流量统计"; fi
    ui_option 6 "设置月度统计起点"
    ui_footer "返回主菜单"
    read -r -p "  请选择: " choice || { echo; return; }
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
    ui_page "月度流量限制" "主菜单 › 流量信息"
    traffic_limits_show --menu || true
    ui_section "额度操作"
    if traffic_limits_are_enabled; then
      ui_option 1 "刷新状态"
      ui_option 2 "设置 / 修改入站额度"
      ui_option 3 "取消入站额度"
      ui_option 4 "关闭流量限制"
    else
      ui_option 1 "启用流量限制"
    fi
    ui_footer "返回流量信息"
    read -r -p "  请选择: " choice || { echo; return; }
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
    ui_page "sbctl · sing-box 管理控制台" "" "v${SBCTL_VERSION}"
    node_summary
    show_main_inbounds
    ui_section "代理与路由"
    ui_option 1 "入站管理"
    ui_option 2 "出站管理"
    ui_section "证书与流量"
    ui_option 3 "TLS 证书"
    ui_option 4 "流量信息"
    ui_section "系统与运维"
    ui_option 5 "BBR 启用 / 关闭"
    ui_option 6 "服务管理"
    ui_option 7 "卸载"
    ui_footer "退出"
    read -r -p "  请选择: " choice || { echo; return; }
    case $choice in
      1) inbound_menu;; 2) outbound_menu;; 3) certificate_menu;; 4) traffic_menu;;
      5) run_menu_action toggle_bbr; pause;; 6) service_menu;; 7) clear_screen; run_menu_action uninstall_sing_box; pause;;
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
  sbctl install [版本]              安装/修复 sing-box
  sbctl status                       查看状态
  sbctl start|stop|restart           服务控制
  sbctl enable|disable               开关开机自启
  sbctl logs [行数]                  查看日志
  sbctl traffic                      查看当前月度周期流量
  sbctl traffic period show          查看统一统计起点
  sbctl traffic period set <日> <时:分> 设置统一统计起点
  sbctl traffic enable|disable       开启/停止流量统计
  sbctl traffic limit show|enable|disable
  sbctl traffic limit set <标签> <GB> <重置日> [HH:MM]
  sbctl traffic limit remove <标签>

  sbctl inbound list                 列出入站
  sbctl inbound add                  新增入站
  sbctl inbound show <标签>          查看入站 JSON
  sbctl inbound rename <旧标签> <新标签>
  sbctl inbound modify [标签]        修改监听地址/端口
  sbctl inbound security [标签]      修改 TLS/REALITY
  sbctl inbound transport [标签]     修改 TCP/WS 传输
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
  sbctl client delete [标签] [用户] [--yes]

  sbctl link [标签] [用户]           输出分享信息/客户端 JSON
  sbctl subscription [标签]          输出 Base64 订阅
  sbctl config check|show|edit|migrate-tags
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
  sbctl version

证书说明:
  - 域名支持 Cloudflare DNS 自动验证/续期、HTTP 自动验证/续期、DNS 手动 TXT 验证。
  - Cloudflare 使用账号邮箱 + Global API Key，凭据文件权限为 600。
  - DNS 手动验证证书不会被标记为自动续期。
  - 公网 IP 证书使用 Certbot 5.4+ short-lived profile + HTTP 验证。
  - Certbot 使用 /opt/sbctl/certbot 独立环境，不污染系统 Certbot。

支持入站: AnyTLS、Hysteria2、SOCKS5、HTTP
出站: SOCKS5/HTTP 代理、本地出口
EOF_HELP
}

# ---- canonical dispatch (merged from all modules) ----
dispatch() {
  local cmd=${1:-menu}; shift || true
  case $cmd in
    menu) main_menu;;
    help|-h|--help) show_help;;
    version|-v|--version) printf 'sbctl %s' "$SBCTL_VERSION"; [[ $SBCTL_BUILD_COMMIT == development ]] || printf ' (commit %s)' "$SBCTL_BUILD_COMMIT"; printf '\n';;
    install) install_or_update_sing_box "${1-}";;
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
            set) traffic_limit_set "${3-}" "${4-}" "${5-}" "${6-}";;
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
        transport|stream) modify_inbound_transport "${2-}";;
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
        delete|remove) delete_client "${2-}" "${3-}" "$([[ ${4-} == --yes ]] && printf 1 || printf 0)";;
        *) die "未知 client 子命令：${1}";;
      esac
      ;;
    link|links|share) print_share "${1-}" "${2-}";;
    subscription|subscribe|sub) print_subscription "${1-}";;
    config)
      case ${1:-check} in
        check|test) check_config;;
        show) ensure_config; jq . "$CONFIG_FILE";;
        edit) edit_config;;
        migrate-tags) ensure_config; normalize_config_tags;;
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
    internal-hy2-hop-restore) internal_hy2_hop_restore;;
    internal-hy2-hop-clear) internal_hy2_hop_clear;;
    internal-traffic-collect) internal_traffic_collect;;
    internal-traffic-watch) internal_traffic_watch;;
    *) error "未知命令：$cmd"; show_help; return 2;;
  esac
}
