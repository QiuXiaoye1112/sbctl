rename_inbound() {
  ensure_dependencies inbound-rename; ensure_config
  local old=${1-} new=${2-} tmp meta_tmp
  [[ -n $old ]] || select_inbound old || return
  inbound_exists "$old" || die "找不到入站：$old"
  if [[ -z $new ]]; then
    while true; do
      prompt_value new "新入站名称" "$old"
      [[ $new == "$old" ]] && { info "名称未更改。"; return 0; }
      validate_tag "$new" || { warn "标签只能包含字母、数字、点、下划线和横线。"; continue; }
      if inbound_exists "$new" || outbound_exists "$new"; then warn "标签已存在，请重新输入。"; continue; fi
      break
    done
  fi
  validate_tag "$new" || die "标签格式无效。"
  inbound_exists "$new" && die "入站标签已存在：$new"
  outbound_exists "$new" && die "出站标签已存在：$new"
  tmp=$(temp_file)
  jq --arg old "$old" --arg new "$new" '
    (.inbounds[]|select(.tag==$old)|.tag)=$new |
    .route.rules = ((.route.rules // []) | map(if ((.inbound // [])|index($old)) then .inbound |= map(if .==$old then $new else . end) else . end))' \
    "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then
    init_meta
    meta_tmp=$(temp_file)
    jq --arg old "$old" --arg new "$new" 'if .inbounds[$old] then .inbounds[$new]=.inbounds[$old] | del(.inbounds[$old]) else . end' "$META_FILE" >"$meta_tmp"
    install -m 600 "$meta_tmp" "$META_FILE"; rm -f "$meta_tmp"
    info "入站已重命名：${old} -> ${new}"
  fi
  rm -f "$tmp"
}

modify_inbound_security() {
  ensure_dependencies inbound-security; require_supported_core; ensure_config
  local tag=${1-} type choice tls="" public="" tmp host
  [[ -n $tag ]] || select_inbound tag || return
  inbound_exists "$tag" || die "找不到入站：$tag"
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
  case $type in
    anytls|vless|trojan)
      choose choice "选择 TLS 安全层" "REALITY" "证书 TLS"
      if [[ $choice == 1 ]]; then build_reality_tls tls public; else build_certificate_tls tls; fi
      ;;
    hysteria2)
      info "Hysteria2 必须使用证书 TLS。"
      build_certificate_tls tls
      ;;
    *) die "${type} 入站没有 sbctl 可管理的 TLS/REALITY 安全层。";;
  esac
  tmp=$(temp_file)
  jq --arg tag "$tag" --argjson tls "$tls" --arg type "$type" '
    (.inbounds[]|select(.tag==$tag)|.tls)=$tls |
    if $type=="vless" then
      (.inbounds[]|select(.tag==$tag)|.users) |= map(.flow=(if $tls.reality.enabled==true then "xtls-rprx-vision" else "" end))
    else . end' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then
    host=$(public_host_for_tag "$tag" || true)
    [[ -n $host ]] || prompt_public_host host
    meta_set_inbound "$tag" "$host" "$public"
    info "入站 ${tag} 的安全方式已更新。"
  fi
  rm -f "$tmp"
}

delete_inbound() {
  ensure_dependencies inbound-delete; ensure_config
  local tag=${1-} yes=${2:-0} tmp
  [[ -n $tag ]] || select_inbound tag || return
  inbound_exists "$tag" || die "找不到入站：$tag"
  [[ $yes == 1 ]] || confirm "删除入站 ${tag}？" N || return
  tmp=$(temp_file)
  jq --arg tag "$tag" '
    .inbounds |= map(select(.tag!=$tag)) |
    .route.rules = ((.route.rules // []) | map(select(
      (.action!="route") or ((.inbound // [])!=[$tag]) or
      ((keys_unsorted | sort) != (["action","inbound","outbound"] | sort)))))' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then meta_delete_inbound "$tag"; info "已删除入站 ${tag}。"; fi
  rm -f "$tmp"
}

rename_client() {
  ensure_dependencies client-rename; ensure_config
  local tag=${1-} old=${2-} new=${3-} type field tmp
  [[ -n $tag ]] || select_inbound tag || return
  inbound_exists "$tag" || die "找不到入站：$tag"
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
  field=$(client_label_field "$type")
  if [[ -z $old ]]; then list_clients "$tag"; prompt_value old "旧用户名称"; fi
  client_exists "$tag" "$old" || die "找不到用户：$old"
  if [[ -z $new ]]; then prompt_value new "新用户名称" "$old"; fi
  [[ $new == "$old" ]] && { info "名称未更改。"; return 0; }
  client_exists "$tag" "$new" && die "用户名称已存在：$new"
  tmp=$(temp_file)
  jq --arg tag "$tag" --arg old "$old" --arg new "$new" --arg field "$field" '(.inbounds[]|select(.tag==$tag)|.users[]|select(.[$field]==$old)|.[$field])=$new' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then info "用户已重命名：${old} -> ${new}"; fi
  rm -f "$tmp"
}

print_all_share() {
  ensure_config
  local tag
  if ! jq -e '.inbounds|length>0' "$CONFIG_FILE" >/dev/null; then info "还没有入站。"; return 0; fi
  while IFS= read -r tag; do print_share "$tag" "" || warn "${tag} 分享信息生成失败。"; done < <(jq -r '.inbounds[].tag' "$CONFIG_FILE")
}

service_state_summary() {
  if ! service_exists; then printf '未安装'; elif service_is_active; then printf '运行中'; else printf '已停止'; fi
}
startup_state_summary() {
  if ! service_exists; then printf '未安装'; elif service_is_enabled; then printf '已开启'; else printf '已关闭'; fi
}
sing_box_version_summary() {
  refresh_binary_path
  if ! sing_box_installed; then printf '未安装'; return; fi
  local version; version=$(sing_box_version)
  [[ -n $version ]] && printf '%s' "$version" || printf '已安装'
}

test_certificate_renewal() {
  ensure_dependencies cert-renew
  install_certbot
  certbot renew --dry-run
}

bbr_state_summary() {
  if [[ -r /proc/sys/net/ipv4/tcp_congestion_control ]]; then
    [[ $(< /proc/sys/net/ipv4/tcp_congestion_control) == bbr ]] && printf '已启用' || printf '未启用'
  else printf '不可用'; fi
}

enable_bbr() {
  ensure_dependencies bbr
  command_exists sysctl || die "缺少 sysctl。"
  modprobe tcp_bbr 2>/dev/null || true
  cat >/etc/sysctl.d/99-sbctl-bbr.conf <<'EOF_BBR'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF_BBR
  sysctl -p /etc/sysctl.d/99-sbctl-bbr.conf >/dev/null
  [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == bbr ]] || die "BBR 未成功启用；当前内核可能不支持。"
  info "BBR 已启用。"
}

disable_bbr() {
  ensure_dependencies bbr-disable
  command_exists sysctl || die "缺少 sysctl。"
  local available fallback=""
  available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
  if grep -qw cubic <<<"$available"; then
    fallback=cubic
  elif grep -qw reno <<<"$available"; then
    fallback=reno
  else
    fallback=$(tr ' ' '\n' <<<"$available" | awk '$0!="" && $0!="bbr" {print; exit}')
  fi
  [[ -n $fallback ]] || die "没有找到可用于替代 BBR 的拥塞控制算法。"
  cat >/etc/sysctl.d/99-sbctl-bbr.conf <<EOF_BBR_OFF
net.ipv4.tcp_congestion_control=${fallback}
EOF_BBR_OFF
  sysctl -p /etc/sysctl.d/99-sbctl-bbr.conf >/dev/null
  [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) != bbr ]] || die "BBR 关闭失败。"
  info "BBR 已关闭；当前拥塞控制算法：${fallback}。"
}

toggle_bbr() {
  if [[ -r /proc/sys/net/ipv4/tcp_congestion_control ]] && [[ $(< /proc/sys/net/ipv4/tcp_congestion_control) == bbr ]]; then
    disable_bbr
  else
    enable_bbr
  fi
}

system_diagnostics() {
  ensure_dependencies diagnose
  heading "系统诊断"
  printf '系统: %s %s\n' "$(uname -s)" "$(uname -r)"
  printf '初始化: %s\n' "$(init_system)"
  printf 'sing-box: %s\n' "$(sing_box_version_summary)"
  printf '服务: %s\n' "$(service_state_summary)"
  printf '开机自启: %s\n' "$(startup_state_summary)"
  printf 'BBR: %s\n' "$(bbr_state_summary)"
  printf '配置: %s\n' "$CONFIG_FILE"
  if [[ -f $CONFIG_FILE ]]; then
    printf '入站: %s  |  出站: %s\n' "$(jq '.inbounds|length' "$CONFIG_FILE")" "$(jq '.outbounds|length' "$CONFIG_FILE")"
    validate_candidate "$CONFIG_FILE" && printf '配置检查: 通过\n' || printf '配置检查: 失败\n'
  fi
}

repair_quick_command() {
  ensure_dependencies quick-command
  install_quick_command
  [[ -x $QUICK_COMMAND ]] || die "快捷命令修复失败。"
  info "快捷命令已修复：${QUICK_SYMLINK}"
}
