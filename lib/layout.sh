# UI layout overrides kept separate from protocol/config logic.

list_outbound_overview() {
  ensure_config
  local rows number inbound outbound type address username password width server port
  local number_width=4 inbound_width=4 tag_width=4 protocol_width=4 address_width=4 username_width=4

  heading "入站与出站规则"
  if [[ $(jq '.inbounds|length' "$CONFIG_FILE") == 0 ]]; then
    info "还没有入站。"
  else
    print_table_cell "序号" 6
    print_table_cell "入站" 28
    printf '出站\n'
    number=0
    while IFS= read -r inbound; do
      ((number+=1))
      outbound=$(current_outbound_for_inbound "$inbound")
      print_table_cell "$number" 6
      print_table_cell_clipped "$inbound" 28
      printf '%s\n' "$outbound"
    done < <(jq -r '.inbounds[].tag' "$CONFIG_FILE")
  fi

  heading "SOCKS5 / HTTP 出站"
  if ! jq -e '.outbounds[]?|select(.type=="socks" or .type=="http")' "$CONFIG_FILE" >/dev/null; then
    info "还没有代理出站。"
    return 0
  fi

  rows=$(jq -r '[.outbounds[]?|select(.type=="socks" or .type=="http")] | to_entries[] |
    [.key+1,.value.tag,.value.type,
     ((if (.value.server|contains(":")) then "["+.value.server+"]" else .value.server end)+":"+(.value.server_port|tostring)),
     (if (.value.username // "")=="" then "无" else .value.username end),
     (if (.value.password // "")=="" then "无" else .value.password end)] | @tsv' "$CONFIG_FILE")

  while IFS=$'\t' read -r number outbound type address username password; do
    display_width width "$number"; ((width > number_width)) && number_width=$width
    display_width width "$outbound"; ((width > tag_width)) && tag_width=$width
    display_width width "$type"; ((width > protocol_width)) && protocol_width=$width
    display_width width "$address"; ((width > address_width)) && address_width=$width
    display_width width "$username"; ((width > username_width)) && username_width=$width
  done <<<"$rows"

  ((number_width+=2, tag_width+=2, protocol_width+=2, address_width+=2, username_width+=2))
  print_table_cell "序号" "$number_width"; printf '| '
  print_table_cell "标签" "$tag_width"; printf '| '
  print_table_cell "协议" "$protocol_width"; printf '| '
  print_table_cell "地址" "$address_width"; printf '| '
  print_table_cell "用户" "$username_width"; printf '| 密码\n'

  while IFS=$'\t' read -r number outbound type address username password; do
    print_table_cell "$number" "$number_width"; printf '| '
    print_table_cell "$outbound" "$tag_width"; printf '| '
    print_table_cell "$type" "$protocol_width"; printf '| '
    print_table_cell "$address" "$address_width"; printf '| '
    print_table_cell "$username" "$username_width"; printf '| %s\n' "$password"
  done <<<"$rows"
}

outbound_menu() {
  local choice
  while true; do
    clear_screen
    heading "出站管理"
    list_outbound_overview
    printf '\n1) 选择入站设置出站\n2) 添加 SOCKS5/HTTP 出站\n3) 删除出站\n0) 返回\n'
    read -r -p "请选择: " choice
    case $choice in
      1) run_menu_action assign_outbound; pause;;
      2) run_menu_action add_outbound; pause;;
      3) run_menu_action delete_outbound; pause;;
      0) return;;
      *) warn "无效选项。"; pause;;
    esac
  done
}

manage_inbound_menu() {
  local tag=$1 choice type port security user_count
  while inbound_exists "$tag"; do
    clear_screen
    type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
    port=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen_port' "$CONFIG_FILE")
    security=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|if .tls.reality.enabled==true then "reality" elif .tls.enabled==true then "tls" else "none" end' "$CONFIG_FILE")
    user_count=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|(.users // [])|length' "$CONFIG_FILE")
    heading "入站 · ${tag}"
    printf '协议: %s  |  端口: %s  |  安全: %s\n\n' "$type" "$port" "$security"

    case $type in
      vless|trojan|hysteria2)
        printf '1) 分享信息\n2) 用户管理\n3) 修改入站信息\n4) 查看 JSON\n0) 返回列表\n'
        read -r -p "请选择: " choice
        case $choice in
          1) run_menu_action print_share "$tag"; pause;;
          2) client_menu "$tag";;
          3) modify_inbound_menu "$tag";;
          4) run_menu_action show_inbound "$tag"; pause;;
          0) return;; *) warn "无效选项。"; pause;;
        esac
        ;;
      anytls)
        printf '1) 客户端配置\n2) 用户管理\n3) 修改入站信息\n4) 查看 JSON\n0) 返回列表\n'
        read -r -p "请选择: " choice
        case $choice in
          1) run_menu_action print_share "$tag"; pause;;
          2) client_menu "$tag";;
          3) modify_inbound_menu "$tag";;
          4) run_menu_action show_inbound "$tag"; pause;;
          0) return;; *) warn "无效选项。"; pause;;
        esac
        ;;
      socks|http|mixed)
        if ((user_count > 0)); then
          printf '1) 客户端配置\n2) 用户管理\n3) 修改入站信息\n4) 查看 JSON\n0) 返回列表\n'
          read -r -p "请选择: " choice
          case $choice in
            1) run_menu_action print_share "$tag"; pause;;
            2) client_menu "$tag";;
            3) modify_inbound_menu "$tag";;
            4) run_menu_action show_inbound "$tag"; pause;;
            0) return;; *) warn "无效选项。"; pause;;
          esac
        else
          printf '1) 客户端配置\n2) 修改入站信息\n3) 查看 JSON\n0) 返回列表\n'
          read -r -p "请选择: " choice
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

inbound_menu() {
  local choice tag
  while true; do
    clear_screen
    heading "入站管理"
    list_inbounds
    printf '\n完整配置: %s\n\n' "$CONFIG_FILE"
    printf '1) 新增入站\n2) 管理已有入站\n3) 订阅链接\n4) 删除入站\n0) 返回\n'
    read -r -p "请选择: " choice
    case $choice in
      1) run_menu_action add_inbound; pause;;
      2) select_inbound tag && manage_inbound_menu "$tag";;
      3) run_menu_action print_all_share; pause;;
      4) run_menu_action delete_inbound; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}
