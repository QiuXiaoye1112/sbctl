# Supported inbound set and creation flow.
# Mixed(SOCKS+HTTP) is intentionally not offered or created by sbctl.

build_inbound() {
  local __json=$1 __host=$2 __public=$3 __hop=${4-} choice type tag listen port client_host
  local tls="" reality_public="" name="" password="" uuid="" flow=""
  local obfs_choice="" obfs_password="" up="" down="" hop_choice="" hop_range=""
  choose choice "选择入站协议" "AnyTLS" "VLESS" "Hysteria2" "Trojan" "SOCKS5" "HTTP"
  case $choice in
    1) type=anytls;;
    2) type=vless;;
    3) type=hysteria2;;
    4) type=trojan;;
    5) type=socks;;
    6) type=http;;
  esac

  prompt_tag tag "${type}-$(random_hex 2)"
  prompt_value listen "监听地址" "0.0.0.0"
  prompt_port port 443
  prompt_public_host client_host

  case $type in
    anytls|vless|trojan)
      choose choice "选择 TLS 安全层" "REALITY" "证书 TLS"
      if [[ $choice == 1 ]]; then build_reality_tls tls reality_public; else build_certificate_tls tls; fi
      ;;
    hysteria2)
      build_certificate_tls tls
      ;;
  esac

  case $type in
    anytls)
      prompt_value name "用户名称" "user-$(random_hex 2)"
      prompt_secret password "AnyTLS 密码" "$(random_password)"
      printf -v "$__json" '%s' "$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg name "$name" --arg password "$password" --argjson tls "$tls" '{type:"anytls",tag:$tag,listen:$listen,listen_port:$port,users:[{name:$name,password:$password}],tls:$tls}')"
      ;;
    vless)
      prompt_value name "用户名称" "user-$(random_hex 2)"
      uuid=$(generate_uuid)
      [[ $(jq -r '.reality.enabled // false' <<<"$tls") == true ]] && flow=xtls-rprx-vision || flow=""
      printf -v "$__json" '%s' "$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg name "$name" --arg uuid "$uuid" --arg flow "$flow" --argjson tls "$tls" '{type:"vless",tag:$tag,listen:$listen,listen_port:$port,users:[{name:$name,uuid:$uuid,flow:$flow}],tls:$tls}')"
      ;;
    hysteria2)
      prompt_value name "用户名称" "user-$(random_hex 2)"
      prompt_secret password "Hysteria2 密码" "$(random_password)"
      prompt_optional_positive_int up "上行限制 Mbps（留空=不限）"
      prompt_optional_positive_int down "下行限制 Mbps（留空=不限）"
      choose obfs_choice "QUIC 混淆" "关闭" "Salamander"
      if [[ $obfs_choice == 2 ]]; then prompt_secret obfs_password "混淆密码" "$(random_password)"; fi
      if [[ -t 0 ]]; then
        choose hop_choice "端口跳跃" "关闭" "开启"
        if [[ $hop_choice == 2 ]]; then
          while true; do
            prompt_value hop_range "跳跃端口范围" "20000-50000"
            validate_hy2_hop_range "$hop_range" || { warn "请输入合法范围，例如 20000-50000。"; continue; }
            hy2_hop_check_conflicts "$tag" "$hop_range" || { warn "请换一个不冲突的端口范围。"; continue; }
            break
          done
          warn "该范围内的入站 UDP 流量会重定向到此 Hysteria2 入站；请勿覆盖其他 UDP 服务使用的端口。"
        fi
      fi
      printf -v "$__json" '%s' "$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg name "$name" --arg password "$password" --arg up "$up" --arg down "$down" --arg obfs "$obfs_password" --argjson tls "$tls" '
        {type:"hysteria2",tag:$tag,listen:$listen,listen_port:$port,users:[{name:$name,password:$password}],tls:$tls} |
        if $up!="" then .up_mbps=($up|tonumber) else . end |
        if $down!="" then .down_mbps=($down|tonumber) else . end |
        if $obfs!="" then .obfs={type:"salamander",password:$obfs} else . end')"
      ;;
    trojan)
      prompt_value name "用户名称" "user-$(random_hex 2)"
      prompt_secret password "Trojan 密码" "$(random_password)"
      printf -v "$__json" '%s' "$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg name "$name" --arg password "$password" --argjson tls "$tls" '{type:"trojan",tag:$tag,listen:$listen,listen_port:$port,users:[{name:$name,password:$password}],tls:$tls}')"
      ;;
    socks|http)
      prompt_optional name "用户名（留空=无认证）"
      if [[ -n $name ]]; then prompt_secret password "密码" "$(random_password)"; fi
      if [[ -n $name ]]; then
        printf -v "$__json" '%s' "$(jq -n --arg type "$type" --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg user "$name" --arg pass "$password" '{type:$type,tag:$tag,listen:$listen,listen_port:$port,users:[{username:$user,password:$pass}]}')"
      else
        [[ $listen == 127.0.0.1 || $listen == ::1 ]] || warn "公网无认证代理风险很高。"
        printf -v "$__json" '%s' "$(jq -n --arg type "$type" --arg tag "$tag" --arg listen "$listen" --argjson port "$port" '{type:$type,tag:$tag,listen:$listen,listen_port:$port,users:[]}')"
      fi
      ;;
  esac

  printf -v "$__host" '%s' "$client_host"
  printf -v "$__public" '%s' "$reality_public"
  [[ -z $__hop ]] || printf -v "$__hop" '%s' "$hop_range"
}

show_help() {
  cat <<'EOF_HELP'
sbctl - sing-box Linux 管理器

用法:
  sbctl                              打开交互菜单
  sbctl install [版本]               安装/更新 sing-box
  sbctl uninstall [--purge]          卸载；--purge 完全删除 sbctl 管理内容
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

  sbctl link [标签] [用户]           输出分享信息/客户端配置
  sbctl config check|show|edit
  sbctl cert list|renew-test
  sbctl cert issue [域名] [邮箱]
  sbctl cert import [标识] [证书] [私钥]
  sbctl cert delete [标识]
  sbctl backup [文件.tar.gz]
  sbctl restore [文件.tar.gz]
  sbctl bbr                           BBR 开启/关闭
  sbctl diagnose
  sbctl version

支持入站: AnyTLS、VLESS、Hysteria2、Trojan、SOCKS5、HTTP
代理出站: SOCKS5、HTTP
EOF_HELP
}
