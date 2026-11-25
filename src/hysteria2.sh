# shellcheck shell=bash
# Hysteria2 UDP port hopping support — NAT redirect table/chain for HY2.
# Inbound and uninstall call this domain's synchronization API directly.

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

hy2_port_in_default_hop_range() {
  hy2_port_in_range "$1" "30000-50000"
}

hy2_hop_rows() {
  [[ -f $META_FILE ]] || return 0
  local config
  config=$(jq -c '.inbounds // []' "$CONFIG_FILE") || return 1
  jq -r --argjson inbounds "$config" '
    .inbounds | to_entries[] | select(.value.hysteria2PortHopping.enabled==true) |
    .key as $tag | ($inbounds | map(select(.tag==$tag and .type=="hysteria2")) | first) as $inbound |
    [$tag,.value.hysteria2PortHopping.range,($inbound.listen // "::"),($inbound.listen_port // 0)] | @tsv
  ' "$META_FILE"
}

hy2_port_in_any_hop_range() {
  local port=$1 address=${2:-::} tag range bind target
  while IFS=$'\t' read -r tag range bind target; do
    [[ -n $tag ]] && hy2_port_in_range "$port" "$range" && listener_addresses_overlap "$address" "$bind" && return 0
  done < <(hy2_hop_rows)
  return 1
}

hy2_internal_port_available() {
  local port=$1 range=$2 address=${3:-::}
  validate_port "$port" || return 1
  hy2_port_in_default_hop_range "$port" && return 1
  hy2_port_in_range "$port" "$range" && return 1
  hy2_port_in_any_hop_range "$port" "$address" && return 1
  port_in_config "$port" "" "$address" && return 1
  port_in_use_os "$port" "$address" && return 1
  return 0
}

hy2_pick_internal_port() {
  local __var=$1 range=$2 address=${3:-::} candidate hex i
  for ((i=0; i<256; i++)); do
    hex=$(random_hex 2); candidate=$((10000 + (16#$hex % 55536)))
    if hy2_internal_port_available "$candidate" "$range" "$address"; then printf -v "$__var" '%s' "$candidate"; return 0; fi
  done
  for ((candidate=10000; candidate<=65535; candidate++)); do
    if hy2_internal_port_available "$candidate" "$range" "$address"; then printf -v "$__var" '%s' "$candidate"; return 0; fi
  done
  return 1
}

prompt_hy2_internal_port() {
  local __var=$1 range=$2 address=${3:-::} value=""
  while true; do
    prompt_optional value "内部监听端口（留空自动选择）" || return 1
    if [[ -z $value ]]; then
      hy2_pick_internal_port value "$range" "$address" || { error "找不到可用的内部监听端口。"; return 1; }
      info "内部监听端口：${value}"; printf -v "$__var" '%s' "$value"; return 0
    fi
    validate_port "$value" || { warn "端口必须为 1-65535。"; continue; }
    value=$((10#$value))
    if hy2_port_in_range "$value" "$range" || hy2_port_in_any_hop_range "$value" "$address"; then
      warn "内部监听端口不能落在此地址的跳跃范围内。"; continue
    fi
    port_in_config "$value" "" "$address" && { warn "该地址的端口已被其他 sing-box 入站使用。"; continue; }
    port_in_use_os "$value" "$address" && { warn "该地址的端口已被占用。"; continue; }
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

hy2_bandwidth_display() {
  if [[ ${1:-0} == 0 ]]; then printf '不限'; else printf '%s Mbps' "$1"; fi
}

prompt_hy2_bandwidth() {
  local __var=$1 label=$2 input
  while true; do
    prompt_optional input "$label" || return 1
    if [[ -z $input || $input =~ ^[0-9]+$ ]]; then
      printf -v "$__var" '%s' "$input"
      return 0
    fi
    warn "请输入非负整数，或直接回车保留当前设置。"
  done
}

hy2_modify_bandwidth() {
  local tag=$1 current current_up current_down up down tmp rc=0
  ensure_dependencies inbound-modify; require_supported_core; ensure_config
  current=$(jq -er --arg tag "$tag" '
    .inbounds[] | select(.tag==$tag and .type=="hysteria2") |
    [(.up_mbps // 0), (.down_mbps // 0)] | @tsv
  ' "$CONFIG_FILE") || { error "找不到 Hysteria2 入站：$tag"; return 1; }
  IFS=$'\t' read -r current_up current_down <<<"$current"

  ui_page "修改上下行限速 · ${tag}" "主菜单 › 入站管理"
  ui_field "当前上行" "$(hy2_bandwidth_display "$current_up")"
  ui_field "当前下行" "$(hy2_bandwidth_display "$current_down")"
  printf '\n  回车保留当前设置，输入 0 表示不限。\n'
  prompt_hy2_bandwidth up "上行限速 (Mbps)" || return 1
  prompt_hy2_bandwidth down "下行限速 (Mbps)" || return 1
  if [[ -z $up && -z $down ]]; then info "上下行限速未更改。"; return 0; fi

  tmp=$(temp_file) || return 1
  if jq --arg tag "$tag" --arg up "$up" --arg down "$down" '
    def update($field; $value):
      if $value == "" then .
      elif ($value | tonumber) == 0 then del(.[$field])
      else .[$field] = ($value | tonumber)
      end;
    (.inbounds[] | select(.tag==$tag and .type=="hysteria2")) |=
      (update("up_mbps"; $up) | update("down_mbps"; $down))
  ' "$CONFIG_FILE" >"$tmp"; then
    if jq -es '.[0] == .[1]' "$CONFIG_FILE" "$tmp" >/dev/null; then
      info "上下行限速未更改。"
    else
      apply_candidate "$tmp" || rc=$?
    fi
  else
    rc=$?
  fi
  rm -f "$tmp"
  return "$rc"
}

hy2_hop_check_conflicts() {
  local range=$1 except_tag=${2-} address=${3:-::} new_start new_end tag existing existing_start existing_end bound port rows
  validate_hy2_hop_range "$range" || return 1
  new_start=${range%-*}; new_end=${range#*-}
  rows=$(hy2_hop_rows) || return 1
  while IFS=$'\t' read -r tag existing bound port; do
    [[ -n $tag && $tag != "$except_tag" ]] || continue
    validate_hy2_hop_range "$existing" || return 1
    existing_start=${existing%-*}; existing_end=${existing#*-}
    if ((10#$new_start <= 10#$existing_end && 10#$new_end >= 10#$existing_start)) &&
       listener_addresses_overlap "$address" "$bound"; then
      warn "此地址的端口跳跃范围与入站 ${tag} 的 ${existing} 重叠。"
      return 1
    fi
  done <<<"$rows"
  rows=$(jq -r --arg except "$except_tag" '
    .inbounds[]? | select(.tag!=$except and (.type=="hysteria2" or .type=="socks")) |
    [.tag,.listen_port,(.listen // "::")] | @tsv
  ' "$CONFIG_FILE") || return 1
  while IFS=$'\t' read -r tag port bound; do
    [[ -n $tag ]] || continue
    if hy2_port_in_range "$port" "$range" && listener_addresses_overlap "$address" "$bound"; then
      warn "跳跃范围覆盖了入站 ${tag} 的 UDP 监听端口 ${port}。"
      return 1
    fi
  done <<<"$rows"
  if port_in_use_os "$range" "$address" "$except_tag" udp; then
    warn "跳跃范围覆盖了此地址上正在使用的 UDP 端口。"
    return 1
  fi
  return 0
}

hy2_hop_range_for_tag() {
  local tag=$1
  [[ -f $META_FILE ]] || return 0
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
    .inbounds[$tag].hysteria2PortHopping={enabled:true,range:$range}' "$META_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
  install -m 600 "$tmp" "$META_FILE" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

hy2_hop_meta_disable() {
  local tag=$1 tmp
  init_meta
  tmp=$(temp_file)
  jq --arg tag "$tag" 'del(.inbounds[$tag].hysteria2PortHopping)' "$META_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
  install -m 600 "$tmp" "$META_FILE" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

hy2_hop_enabled_count() {
  [[ -f $META_FILE ]] || { printf '0'; return; }
  [[ -f $CONFIG_FILE ]] || { printf '0'; return; }
  jq --slurpfile config "$CONFIG_FILE" '
    [.inbounds|to_entries[]?|.key as $tag|
      select(.value.hysteria2PortHopping.enabled==true and
             (.value.hysteria2PortHopping.range//"")!="" and
             any($config[0].inbounds[]?; .tag==$tag))]|length' "$META_FILE"
}

hy2_hop_ensure_backend() {
  if command_exists nft || command_exists iptables || command_exists ip6tables; then return 0; fi
  info "端口跳跃需要 nftables/iptables，正在安装 nftables..."
  if ! (install_packages nftables) || ! command_exists nft; then
    warn "nftables 安装失败，无法启用 Hysteria2 端口跳跃。"
    return 1
  fi
}

hy2_hop_clear_rules() {
  if command_exists nft; then
    if nft list table inet sbctl_hy2_hop >/dev/null 2>&1; then
      nft delete table inet sbctl_hy2_hop || return 1
    fi
  fi
  hy2_hop_clear_iptables_rules
}

hy2_hop_clear_iptables_rules() {
  local cmd
  for cmd in iptables ip6tables; do
    command_exists "$cmd" || continue
    while "$cmd" -t nat -C PREROUTING -p udp -j SBCTL_HY2_HOP >/dev/null 2>&1; do
      "$cmd" -t nat -D PREROUTING -p udp -j SBCTL_HY2_HOP || return 1
    done
    # Older installations attempted a jump without the UDP match.
    while "$cmd" -t nat -C PREROUTING -j SBCTL_HY2_HOP >/dev/null 2>&1; do
      "$cmd" -t nat -D PREROUTING -j SBCTL_HY2_HOP || return 1
    done
    if "$cmd" -t nat -S SBCTL_HY2_HOP >/dev/null 2>&1; then
      "$cmd" -t nat -F SBCTL_HY2_HOP && "$cmd" -t nat -X SBCTL_HY2_HOP || return 1
    fi
  done
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
  [[ -x $QUICK_COMMAND ]] || install_quick_command || return 1
  case $(init_system) in
    systemd)
      cat >"${SYSTEMD_UNIT_DIR}/sbctl-hy2-hop-restore.service" <<EOF_UNIT || return 1
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
      systemctl daemon-reload || return 1
      systemctl enable sbctl-hy2-hop-restore.service >/dev/null 2>&1 || return 1
      ;;
    openrc)
      cat >"${OPENRC_INIT_DIR}/sbctl-hy2-hop-restore" <<EOF_RC || return 1
#!/sbin/openrc-run
name="sbctl-hy2-hop-restore"
description="Restore sbctl Hysteria2 port hopping NAT rules"
depend() { need net; }
start() { "${QUICK_COMMAND}" internal-hy2-hop-restore; }
EOF_RC
      chmod 755 "${OPENRC_INIT_DIR}/sbctl-hy2-hop-restore" || return 1
      rc-update add sbctl-hy2-hop-restore default >/dev/null 2>&1 || return 1
      ;;
  esac
}

hy2_hop_restore_all() {
  [[ $(uname -s) == Linux ]] || return 0
  [[ -f $CONFIG_FILE ]] || { hy2_hop_clear_rules; return; }
  local count tag range target start end cmd address ip endpoint rows
  local -a match=() destination=()
  count=$(hy2_hop_enabled_count)
  if ((count == 0)); then hy2_hop_clear_rules; return; fi
  hy2_hop_ensure_backend || return 1
  rows=$(hy2_hop_rows) || return 1
  if command_exists nft; then
    local batch rc=0
    batch=$(temp_file) || return 1
    if nft list table inet sbctl_hy2_hop >/dev/null 2>&1; then
      printf '%s\n' 'delete table inet sbctl_hy2_hop' >>"$batch"
    fi
    printf '%s\n' 'add table inet sbctl_hy2_hop' 'add chain inet sbctl_hy2_hop prerouting { type nat hook prerouting priority dstnat; policy accept; }' >>"$batch"
    while IFS=$'\t' read -r tag range address target; do
      [[ -n $tag && $target != 0 ]] || continue
      validate_hy2_hop_range "$range" && validate_port "$target" && ip=$(normalize_socket_ip "$address") || { rc=1; break; }
      range="$((10#${range%-*}))-$((10#${range#*-}))"
      case $ip in
        0.0.0.0|::) printf 'add rule inet sbctl_hy2_hop prerouting udp dport %s redirect to :%s\n' "$range" "$target" ;;
        *:*) printf 'add rule inet sbctl_hy2_hop prerouting ip6 daddr %s udp dport %s dnat ip6 to [%s]:%s\n' "$ip" "$range" "$ip" "$target" ;;
        *) printf 'add rule inet sbctl_hy2_hop prerouting ip daddr %s udp dport %s dnat ip to %s:%s\n' "$ip" "$range" "$ip" "$target" ;;
      esac >>"$batch"
    done <<<"$rows"
    if ((rc == 0)); then
      if nft -f "$batch"; then hy2_hop_clear_iptables_rules || rc=1; else rc=1; fi
    fi
    rm -f "$batch"
    return "$rc"
  else
    while IFS=$'\t' read -r tag range address target; do
      [[ -n $tag && $target != 0 ]] || continue
      validate_hy2_hop_range "$range" && validate_port "$target" && ip=$(normalize_socket_ip "$address") || return 1
      case $ip in
        0.0.0.0|::) ;;
        *:*) command_exists ip6tables || { warn "IPv6 端口跳跃需要 ip6tables。"; return 1; } ;;
        *) command_exists iptables || { warn "IPv4 端口跳跃需要 iptables。"; return 1; } ;;
      esac
    done <<<"$rows"
    for cmd in iptables ip6tables; do
      command_exists "$cmd" || continue
      "$cmd" -t nat -N SBCTL_HY2_HOP >/dev/null 2>&1 || true
      "$cmd" -t nat -F SBCTL_HY2_HOP || return 1
      "$cmd" -t nat -C PREROUTING -p udp -j SBCTL_HY2_HOP >/dev/null 2>&1 || "$cmd" -t nat -A PREROUTING -p udp -j SBCTL_HY2_HOP || return 1
    done
    while IFS=$'\t' read -r tag range address target; do
      [[ -n $tag && $target != 0 ]] || continue
      validate_hy2_hop_range "$range" && validate_port "$target" && ip=$(normalize_socket_ip "$address") || return 1
      start=$((10#${range%-*})); end=$((10#${range#*-}))
      for cmd in iptables ip6tables; do
        command_exists "$cmd" || continue
        match=()
        case $ip in
          0.0.0.0|::) destination=(-j REDIRECT --to-ports "$target") ;;
          *:*) [[ $cmd == ip6tables ]] || continue; match=(-d "$ip"); endpoint="[$ip]:$target"; destination=(-j DNAT --to-destination "$endpoint") ;;
          *) [[ $cmd == iptables ]] || continue; match=(-d "$ip"); endpoint="$ip:$target"; destination=(-j DNAT --to-destination "$endpoint") ;;
        esac
        "$cmd" -t nat -A SBCTL_HY2_HOP "${match[@]}" -p udp --dport "${start}:${end}" "${destination[@]}" || return 1
      done
    done <<<"$rows"
  fi
}

# Sync all hop rules after CRUD operations (called from inbound.sh)
hy2_hop_sync() {
  local count
  count=$(hy2_hop_enabled_count)
  if ((count > 0)); then
    hy2_hop_restore_all || return 1
    hy2_hop_boot_service_ensure || return 1
  else
    hy2_hop_clear_rules || return 1
    hy2_hop_boot_service_remove
  fi
}

hy2_hop_configure() {
  local tag=$1 assume_yes=${2:-0} range current address choice tmp meta_tmp port rc=0
  ensure_dependencies inbound-hopping
  ensure_config
  inbound_exists "$tag" || { warn "入站不存在：$tag"; return 1; }
  jq -e --arg tag "$tag" 'any(.inbounds[]; .tag==$tag and .type=="hysteria2")' "$CONFIG_FILE" >/dev/null ||
    { warn "端口跳跃仅支持 Hysteria2 入站。"; return 1; }
  address=$(inbound_listen "$tag") || return 1
  current=$(hy2_hop_range_for_tag "$tag") || return 1
  choice=1
  if [[ -n $current && $assume_yes != 1 ]]; then
    printf '当前端口跳跃范围: %s\n1) 修改范围\n2) 关闭\n0) 返回\n' "$current"
    read -r -p "请选择: " choice || { echo; return 0; }
    case $choice in 1|2) ;; 0) return 0;; *) warn "无效选项。"; return 1;; esac
  fi

  range=""
  port=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .listen_port' "$CONFIG_FILE") || return 1
  if [[ $choice == 1 ]]; then
    while true; do
      prompt_value range "端口跳跃范围" "${current:-30000-50000}" || return 1
      validate_hy2_hop_range "$range" || { warn "格式：起始端口-结束端口，起始端口必须小于结束端口。"; continue; }
      hy2_hop_check_conflicts "$range" "$tag" "$address" && break
    done
    if hy2_port_in_range "$port" "$range"; then
      info "内部监听端口 ${port} 位于跳跃范围内，正在分配新端口。"
      hy2_pick_internal_port port "$range" "$address" || { warn "无法分配可用端口。"; return 1; }
    fi
  fi

  init_meta
  tmp=$(temp_file) || return 1
  meta_tmp=$(temp_file) || { rm -f "$tmp"; return 1; }
  if ! jq --arg tag "$tag" --argjson port "$port" '(.inbounds[] | select(.tag==$tag) | .listen_port)=$port' "$CONFIG_FILE" >"$tmp" ||
     ! jq --arg tag "$tag" --arg range "$range" '
       if $range=="" then del(.inbounds[$tag].hysteria2PortHopping)
       else .inbounds[$tag].hysteria2PortHopping={enabled:true,range:$range} end
     ' "$META_FILE" >"$meta_tmp"; then
    rm -f "$tmp" "$meta_tmp"
    return 1
  fi
  apply_candidate_with_meta "$tmp" "$meta_tmp" 1 || rc=$?
  rm -f "$tmp" "$meta_tmp"
  ((rc == 0)) || return "$rc"
  if [[ -n $range ]]; then
    info "Hysteria2 端口跳跃已启用：${range} -> UDP ${port}"
  else
    info "端口跳跃已关闭。"
  fi
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
