# Hysteria2 UDP port hopping support.
# This module only manages a dedicated NAT redirect table/chain for HY2.

validate_hy2_hop_range() {
  local value=${1:-} start end
  [[ $value =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]] || return 1
  start=${BASH_REMATCH[1]}; end=${BASH_REMATCH[2]}
  validate_port "$start" && validate_port "$end" && ((10#$start < 10#$end))
}

hy2_hop_range_for_tag() {
  local tag=$1
  init_meta
  jq -r --arg tag "$tag" '.inbounds[$tag].hysteria2PortHopping.range // empty' "$META_FILE"
}

hy2_hop_client_port_spec() {
  local tag=$1 fallback=$2 range
  range=$(hy2_hop_range_for_tag "$tag")
  if [[ -n $range ]]; then printf '%s' "$range"; else printf '%s' "$fallback"; fi
}

hy2_hop_meta_set() {
  local tag=$1 range=$2 tmp
  init_meta
  tmp=$(temp_file)
  jq --arg tag "$tag" --arg range "$range" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
    .inbounds[$tag]=((.inbounds[$tag]//{})+{updatedAt:$now}) |
    .inbounds[$tag].hysteria2PortHopping={enabled:true,range:$range}' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"
  rm -f "$tmp"
}

hy2_hop_meta_disable() {
  local tag=$1 tmp
  init_meta
  tmp=$(temp_file)
  jq --arg tag "$tag" 'del(.inbounds[$tag].hysteria2PortHopping)' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"
  rm -f "$tmp"
}

hy2_hop_enabled_count() {
  init_meta
  jq '[.inbounds[]?|select(.hysteria2PortHopping.enabled==true and (.hysteria2PortHopping.range//"")!="")]|length' "$META_FILE"
}

hy2_hop_clear_rules() {
  if command_exists nft; then
    nft delete table inet sbctl_hy2_hop >/dev/null 2>&1 || true
  fi
  local cmd
  for cmd in iptables ip6tables; do
    command_exists "$cmd" || continue
    "$cmd" -t nat -D PREROUTING -p udp -j SBCTL_HY2_HOP >/dev/null 2>&1 || true
    "$cmd" -t nat -F SBCTL_HY2_HOP >/dev/null 2>&1 || true
    "$cmd" -t nat -X SBCTL_HY2_HOP >/dev/null 2>&1 || true
  done
}

hy2_hop_ensure_backend() {
  if command_exists nft || command_exists iptables; then return 0; fi
  info "端口跳跃需要 nftables/iptables，正在安装 nftables..."
  install_packages nftables
  command_exists nft || die "nftables 安装失败，无法启用 Hysteria2 端口跳跃。"
}

hy2_hop_restore_all() {
  [[ $(uname -s) == Linux ]] || return 0
  init_meta
  local count tag range target start end cmd
  count=$(hy2_hop_enabled_count)
  if ((count == 0)); then
    hy2_hop_clear_rules
    return 0
  fi

  hy2_hop_ensure_backend
  if command_exists nft; then
    nft delete table inet sbctl_hy2_hop >/dev/null 2>&1 || true
    nft add table inet sbctl_hy2_hop
    nft 'add chain inet sbctl_hy2_hop prerouting { type nat hook prerouting priority dstnat; policy accept; }'
    while IFS=$'\t' read -r tag range; do
      [[ -n $tag && -n $range ]] || continue
      target=$(jq -r --arg tag "$tag" '.inbounds[]?|select(.tag==$tag and .type=="hysteria2")|.listen_port // empty' "$CONFIG_FILE" 2>/dev/null || true)
      validate_port "$target" || continue
      nft add rule inet sbctl_hy2_hop prerouting udp dport "$range" redirect to ":${target}" comment "sbctl:${tag}"
    done < <(jq -r '.inbounds|to_entries[]|select(.value.hysteria2PortHopping.enabled==true)|[.key,.value.hysteria2PortHopping.range]|@tsv' "$META_FILE")
  else
    for cmd in iptables ip6tables; do
      command_exists "$cmd" || continue
      "$cmd" -t nat -N SBCTL_HY2_HOP >/dev/null 2>&1 || true
      "$cmd" -t nat -F SBCTL_HY2_HOP
      "$cmd" -t nat -C PREROUTING -p udp -j SBCTL_HY2_HOP >/dev/null 2>&1 || "$cmd" -t nat -A PREROUTING -p udp -j SBCTL_HY2_HOP
    done
    while IFS=$'\t' read -r tag range; do
      [[ -n $tag && -n $range ]] || continue
      target=$(jq -r --arg tag "$tag" '.inbounds[]?|select(.tag==$tag and .type=="hysteria2")|.listen_port // empty' "$CONFIG_FILE" 2>/dev/null || true)
      validate_port "$target" || continue
      start=${range%-*}; end=${range#*-}
      for cmd in iptables ip6tables; do
        command_exists "$cmd" || continue
        "$cmd" -t nat -A SBCTL_HY2_HOP -p udp --dport "${start}:${end}" -j REDIRECT --to-ports "$target"
      done
    done < <(jq -r '.inbounds|to_entries[]|select(.value.hysteria2PortHopping.enabled==true)|[.key,.value.hysteria2PortHopping.range]|@tsv' "$META_FILE")
  fi
}

hy2_hop_boot_service_install() {
  local target=${QUICK_COMMAND:-/usr/local/sbin/sbctl}
  case $(init_system) in
    systemd)
      cat >"${SYSTEMD_UNIT_DIR}/sbctl-hy2-hop.service" <<EOF_UNIT
[Unit]
Description=sbctl Hysteria2 port hopping redirects
After=network-online.target
Wants=network-online.target
Before=${SERVICE_NAME}.service

[Service]
Type=oneshot
ExecStart=${target} internal-hy2-hop-restore
ExecStop=${target} internal-hy2-hop-clear
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_UNIT
      systemctl daemon-reload >/dev/null
      systemctl enable sbctl-hy2-hop.service >/dev/null
      ;;
    openrc)
      cat >"${OPENRC_INIT_DIR}/sbctl-hy2-hop" <<EOF_RC
#!/sbin/openrc-run
name="sbctl Hysteria2 port hopping"
description="Restore sbctl Hysteria2 UDP port hopping redirects"
depend() { need net; before ${SERVICE_NAME}; }
start() { ebegin "Restoring Hysteria2 port hopping"; ${target} internal-hy2-hop-restore; eend \$?; }
stop() { ebegin "Removing Hysteria2 port hopping"; ${target} internal-hy2-hop-clear; eend \$?; }
EOF_RC
      chmod 755 "${OPENRC_INIT_DIR}/sbctl-hy2-hop"
      rc-update add sbctl-hy2-hop default >/dev/null 2>&1 || true
      ;;
  esac
}

hy2_hop_boot_service_remove() {
  case $(init_system) in
    systemd)
      systemctl disable sbctl-hy2-hop.service >/dev/null 2>&1 || true
      rm -f "${SYSTEMD_UNIT_DIR}/sbctl-hy2-hop.service"
      systemctl daemon-reload >/dev/null 2>&1 || true
      ;;
    openrc)
      rc-update del sbctl-hy2-hop default >/dev/null 2>&1 || true
      rm -f "${OPENRC_INIT_DIR}/sbctl-hy2-hop"
      ;;
  esac
}

hy2_hop_sync() {
  if (( $(hy2_hop_enabled_count) > 0 )); then
    hy2_hop_boot_service_install
    hy2_hop_restore_all
  else
    hy2_hop_clear_rules
    hy2_hop_boot_service_remove
  fi
}

hy2_hop_check_conflicts() {
  local tag=$1 range=$2 start end other other_port
  start=${range%-*}; end=${range#*-}
  while IFS=$'\t' read -r other other_port; do
    [[ $other == "$tag" ]] && continue
    if ((10#$other_port >= 10#$start && 10#$other_port <= 10#$end)); then
      warn "跳跃范围包含其他 Hysteria2 入站端口 ${other_port}（${other}）。"
      return 1
    fi
  done < <(jq -r '.inbounds[]?|select(.type=="hysteria2")|[.tag,(.listen_port|tostring)]|@tsv' "$CONFIG_FILE")
}

hy2_hop_configure() {
  local tag=$1 initial=${2:-0} type choice range current
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
  [[ $type == hysteria2 ]] || die "只有 Hysteria2 入站支持端口跳跃。"
  current=$(hy2_hop_range_for_tag "$tag")

  choose choice "端口跳跃" "关闭" "开启"
  if [[ $choice == 1 ]]; then
    hy2_hop_meta_disable "$tag"
    hy2_hop_sync
    ((initial)) || info "Hysteria2 端口跳跃已关闭。"
    return 0
  fi

  while true; do
    prompt_value range "跳跃端口范围" "${current:-20000-50000}"
    validate_hy2_hop_range "$range" || { warn "请输入合法范围，例如 20000-50000。"; continue; }
    hy2_hop_check_conflicts "$tag" "$range" || { warn "请换一个不与其他 Hysteria2 监听端口冲突的范围。"; continue; }
    break
  done
  warn "该范围内的入站 UDP 流量会被重定向到 ${tag}；请勿覆盖其他 UDP 服务使用的端口。"
  hy2_hop_meta_set "$tag" "$range"
  hy2_hop_sync
  info "Hysteria2 端口跳跃已启用：${range} -> UDP $(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen_port' "$CONFIG_FILE")"
}

# Preserve the implementations loaded before this module and wrap their lifecycle
# so port-hopping rules stay synchronized with config/meta changes.
eval "$(declare -f modify_inbound_basic | sed '1s/^modify_inbound_basic/original_modify_inbound_basic/')"
eval "$(declare -f delete_inbound | sed '1s/^delete_inbound/original_delete_inbound/')"
eval "$(declare -f rename_inbound | sed '1s/^rename_inbound/original_rename_inbound/')"
eval "$(declare -f uninstall_sing_box | sed '1s/^uninstall_sing_box/original_uninstall_sing_box/')"

add_inbound() {
  ensure_dependencies inbound-add; require_supported_core; ensure_config
  local inbound host public tag tmp type
  build_inbound inbound host public
  tag=$(jq -r '.tag' <<<"$inbound")
  type=$(jq -r '.type' <<<"$inbound")
  tmp=$(temp_file)
  jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then
    meta_set_inbound "$tag" "$host" "$public"
    if [[ $type == hysteria2 ]]; then
      if ! hy2_hop_configure "$tag" 1; then warn "端口跳跃配置未完成；Hysteria2 入站本身已创建。"; fi
    fi
    heading "入站已创建"
    show_inbound "$tag"
    print_share "$tag" "" || true
  fi
  rm -f "$tmp"
}

modify_inbound_basic() {
  original_modify_inbound_basic "$@"
  hy2_hop_sync
}

delete_inbound() {
  original_delete_inbound "$@"
  hy2_hop_sync
}

rename_inbound() {
  original_rename_inbound "$@"
  hy2_hop_sync
}

uninstall_sing_box() {
  hy2_hop_clear_rules
  hy2_hop_boot_service_remove
  original_uninstall_sing_box "$@"
}

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
    read -r -p "请选择: " choice
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

internal_hy2_hop_restore() {
  require_root internal-hy2-hop-restore
  hy2_hop_restore_all
}

internal_hy2_hop_clear() {
  require_root internal-hy2-hop-clear
  hy2_hop_clear_rules
}
