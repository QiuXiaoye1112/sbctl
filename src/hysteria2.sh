# shellcheck shell=bash
# Hysteria2 UDP port hopping support — NAT redirect table/chain for HY2.
# No function overrides. Hooks into canonical CRUD via hy2_hop_sync and
# hy2_hop_configure which are called directly from inbound.sh and uninstall.sh.

validate_hy2_hop_range() {
  local value=${1:-} start end
  [[ $value =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]] || return 1
  start=${BASH_REMATCH[1]}; end=${BASH_REMATCH[2]}
  validate_port "$start" && validate_port "$end" && ((10#$start < 10#$end))
}

hy2_port_in_range() {
  local port=$1 range=$2 start end
  start=${range%-*}; end=${range#*-}
  validate_port "$port" && validate_hy2_hop_range "$range" || return 1
  ((10#$port >= 10#$start && 10#$port <= 10#$end))
}

hy2_port_in_any_hop_range() {
  local port=$1 range
  init_meta 2>/dev/null || true
  while IFS= read -r range; do
    [[ -n $range ]] || continue
    hy2_port_in_range "$port" "$range" && return 0
  done < <(jq -r '.inbounds[]?.hysteria2PortHopping.range // empty' "$META_FILE" 2>/dev/null || true)
  return 1
}

hy2_internal_port_available() {
  local port=$1 range=$2
  validate_port "$port" || return 1
  hy2_port_in_range "$port" "$range" && return 1
  port_in_config "$port" && return 1
  port_in_use_os "$port" && return 1
}

hy2_pick_internal_port() {
  local __var=$1 range=$2 candidate hex i
  for ((i=0; i<256; i++)); do
    hex=$(random_hex 2); candidate=$((10000 + (16#$hex % 55536)))
    if hy2_internal_port_available "$candidate" "$range"; then printf -v "$__var" '%s' "$candidate"; return 0; fi
  done
  for ((candidate=10000; candidate<=65535; candidate++)); do
    if hy2_internal_port_available "$candidate" "$range"; then printf -v "$__var" '%s' "$candidate"; return 0; fi
  done
  return 1
}

prompt_hy2_internal_port() {
  local __var=$1 range=$2 value=""
  while true; do
    prompt_optional value "内部监听端口（留空自动选择）" || return 1
    if [[ -z $value ]]; then
      hy2_pick_internal_port value "$range" || { error "找不到可用的内部监听端口。"; return 1; }
      info "内部监听端口：${value}"; printf -v "$__var" '%s' "$value"; return 0
    fi
    validate_port "$value" || { warn "端口必须为 1-65535。"; continue; }
    hy2_port_in_range "$value" "$range" && { warn "内部监听端口不能位于跳跃端口范围 ${range} 内。"; continue; }
    port_in_config "$value" && { warn "该端口已被其他 sing-box 入站使用。"; continue; }
    port_in_use_os "$value" && { warn "系统检测到该端口已被占用，请换一个端口。"; continue; }
    printf -v "$__var" '%s' "$value"; return 0
  done
}

hy2_build() {
  local __out=$1 tag=$2 listen=$3 port=$4 name=$5 password=$6 up=$7 down=$8 obfs=${9-} tls=${10}
  printf -v "$__out" '%s' "$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg name "$name" --arg password "$password" --arg up "$up" --arg down "$down" --arg obfs "$obfs" --argjson tls "$tls" '
    {type:"hysteria2",tag:$tag,listen:$listen,listen_port:$port,users:[{name:$name,password:$password}],tls:$tls} |
    if $up!="" then .up_mbps=($up|tonumber) else . end |
    if $down!="" then .down_mbps=($down|tonumber) else . end |
    if $obfs!="" then .obfs={type:"salamander",password:$obfs} else . end')"
}

hy2_hop_check_conflicts() {
  local range=$1 except_tag=${2-} new_start new_end tag existing existing_start existing_end
  new_start=${range%-*}; new_end=${range#*-}
  init_meta
  while IFS=$'\t' read -r tag existing; do
    [[ -n $tag && -n $existing ]] || continue
    [[ $tag != "$except_tag" ]] || continue
    existing_start=${existing%-*}; existing_end=${existing#*-}
    # Overlap: new_start <= existing_end AND new_end >= existing_start
    if ((10#$new_start <= 10#$existing_end && 10#$new_end >= 10#$existing_start)); then
      warn "端口跳跃范围与入站 ${tag} 的 ${existing} 重叠，请重新选择。"
      return 1
    fi
  done < <(jq -r '.inbounds|to_entries[]|select(.value.hysteria2PortHopping.enabled==true)|[.key,.value.hysteria2PortHopping.range]|@tsv' "$META_FILE")
  return 0
}

# Apply NAT rules only (meta must already be set). Called from add_inbound after apply.
hy2_hop_apply_nat() {
  hy2_hop_sync
  return 0
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

hy2_hop_ensure_backend() {
  if command_exists nft || command_exists iptables; then return 0; fi
  info "端口跳跃需要 nftables/iptables，正在安装 nftables..."
  install_packages nftables
  command_exists nft || die "nftables 安装失败，无法启用 Hysteria2 端口跳跃。"
}

hy2_hop_clear_rules() {
  if command_exists nft; then
    nft delete table inet sbctl_hy2_hop >/dev/null 2>&1 || true
  elif command_exists iptables; then
    iptables -t nat -F SBCTL_HY2_HOP 2>/dev/null || true
    iptables -t nat -D PREROUTING -j SBCTL_HY2_HOP 2>/dev/null || true
    iptables -t nat -X SBCTL_HY2_HOP 2>/dev/null || true
  fi
}

hy2_hop_boot_service_remove() {
  case $(init_system) in
    systemd)
      systemctl disable --now sbctl-hy2-hop-restore.service >/dev/null 2>&1 || true
      rm -f "${SYSTEMD_UNIT_DIR}/sbctl-hy2-hop-restore.service"
      systemctl daemon-reload >/dev/null 2>&1 || true
      ;;
    openrc)
      rc-update del sbctl-hy2-hop-restore default >/dev/null 2>&1 || true
      rm -f "${OPENRC_INIT_DIR}/sbctl-hy2-hop-restore"
      ;;
  esac
}

hy2_hop_boot_service_ensure() {
  [[ -x $QUICK_COMMAND ]] || install_quick_command
  case $(init_system) in
    systemd)
      cat >"${SYSTEMD_UNIT_DIR}/sbctl-hy2-hop-restore.service" <<EOF_UNIT
[Unit]
Description=Restore sbctl Hysteria2 port hopping NAT rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${QUICK_COMMAND} internal-hy2-hop-restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_UNIT
      systemctl daemon-reload
      systemctl enable sbctl-hy2-hop-restore.service >/dev/null 2>&1 || true
      ;;
    openrc)
      cat >"${OPENRC_INIT_DIR}/sbctl-hy2-hop-restore" <<'EOF_RC'
#!/sbin/openrc-run
name="sbctl-hy2-hop-restore"
description="Restore sbctl Hysteria2 port hopping NAT rules"
$(printf '%s' 'depend() { need net; }')
$(printf '%s' 'start() { /usr/local/sbin/sbctl internal-hy2-hop-restore; }')
EOF_RC
      chmod 755 "${OPENRC_INIT_DIR}/sbctl-hy2-hop-restore"
      rc-update add sbctl-hy2-hop-restore default >/dev/null 2>&1 || true
      ;;
  esac
}

# Canonical hy2_hop_restore_all lives in hy2_nft.sh (nftables-aware version)

hy2_hop_restore_all() {
  [[ $(uname -s) == Linux ]] || return 0
  init_meta
  [[ -f $CONFIG_FILE ]] || { hy2_hop_clear_rules; return 0; }
  local count tag range target start end cmd
  count=$(hy2_hop_enabled_count)
  if ((count == 0)); then hy2_hop_clear_rules; return 0; fi
  hy2_hop_ensure_backend
  if command_exists nft; then
    nft delete table inet sbctl_hy2_hop >/dev/null 2>&1 || true
    nft add table inet sbctl_hy2_hop
    nft 'add chain inet sbctl_hy2_hop prerouting { type nat hook prerouting priority dstnat; policy accept; }'
    while IFS=$'\t' read -r tag range; do
      [[ -n $tag && -n $range ]] || continue
      target=$(jq -r --arg tag "$tag" '.inbounds[]?|select(.tag==$tag and .type=="hysteria2")|.listen_port // empty' "$CONFIG_FILE" 2>/dev/null || true)
      validate_port "$target" || continue
      nft add rule inet sbctl_hy2_hop prerouting udp dport "$range" redirect to ":${target}"
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

# Sync all hop rules after CRUD operations (called from inbound.sh)
hy2_hop_sync() {
  hy2_hop_clear_rules
  local count
  count=$(hy2_hop_enabled_count)
  if ((count > 0)); then
    hy2_hop_restore_all
    hy2_hop_boot_service_ensure
  else
    hy2_hop_boot_service_remove
  fi
}

hy2_hop_configure() {
  local tag=$1 assume_yes=${2:-0} type range current
  inbound_exists "$tag" || { warn "入站不存在：$tag"; return 1; }
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
  [[ $type == hysteria2 ]] || { warn "端口跳跃仅支持 Hysteria2 入站。"; return 1; }

  current=$(hy2_hop_range_for_tag "$tag")
  if [[ -n $current ]]; then
    printf '当前端口跳跃范围: %s\n' "$current"
    if [[ $assume_yes != 1 ]]; then
      printf '1) 修改范围\n2) 关闭\n0) 返回\n'
      local choice
      read -r -p "请选择: " choice || { echo; return; }
      case $choice in
        1) :;;
        2) hy2_hop_meta_disable "$tag"; hy2_hop_sync; info "端口跳跃已关闭。"; return 0;;
        0) return 0;;
        *) warn "无效选项。"; return 1;;
      esac
    fi
  fi

  while true; do
    prompt_value range "端口跳跃范围" "${current:-30000-50000}"
    validate_hy2_hop_range "$range" || { warn "格式：起始端口-结束端口，起始端口必须小于结束端口。"; continue; }
    hy2_hop_check_conflicts "$range" "$tag" || continue
    break
  done

  local listen_port internal_port
  listen_port=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen_port' "$CONFIG_FILE")
  if hy2_port_in_range "$listen_port" "$range"; then
    warn "listen_port ${listen_port} 在跳跃范围内，需要重新选择内部端口。"
    hy2_pick_internal_port internal_port "$range" || { warn "无法分配可用端口。"; return 1; }
    local tmp
    tmp=$(temp_file)
    jq --arg tag "$tag" --argjson internal "$internal_port" '(.inbounds[]|select(.tag==$tag)) |= (.listen_port=$internal)' "$CONFIG_FILE" >"$tmp"
    if apply_candidate "$tmp"; then
      hy2_hop_meta_set "$tag" "$range"
      hy2_hop_sync
      info "Hysteria2 端口跳跃已启用：${range} -> UDP ${internal_port}（外部端口通过 NAT 重定向）"
    else
      rm -f "$tmp"
      return 1
    fi
    rm -f "$tmp"
    return 0
  fi

  hy2_hop_meta_set "$tag" "$range"
  hy2_hop_sync
  info "Hysteria2 端口跳跃已启用：${range} -> UDP ${listen_port}"
}

# Internal commands (called via dispatch)
internal_hy2_hop_restore() {
  require_root internal-hy2-hop-restore
  hy2_hop_restore_all
}

internal_hy2_hop_clear() {
  require_root internal-hy2-hop-clear
  hy2_hop_clear_rules
}
