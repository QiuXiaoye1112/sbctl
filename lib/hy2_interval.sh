# Hysteria2 client-side port hopping interval support.
# The server redirect rules do not depend on the interval; it is stored as
# metadata so sbctl can preserve and display the intended client setting.

HY2_SELECTED_HOP_INTERVAL=""

validate_hy2_hop_interval_seconds() {
  local value=${1:-}
  [[ $value =~ ^[0-9]+$ ]] && ((10#$value >= 5))
}

prompt_hy2_hop_interval() {
  local __var=$1 default=${2:-30} value=""
  while true; do
    prompt_value value "跳跃时间间隔（秒）" "$default" || return 1
    validate_hy2_hop_interval_seconds "$value" || {
      warn "跳跃时间间隔至少为 5 秒。"
      continue
    }
    printf -v "$__var" '%ss' "$((10#$value))"
    return 0
  done
}

hy2_hop_interval_for_tag() {
  local tag=$1
  init_meta
  jq -r --arg tag "$tag" '
    if .inbounds[$tag].hysteria2PortHopping.enabled==true then
      (.inbounds[$tag].hysteria2PortHopping.interval // "30s")
    else empty end' "$META_FILE"
}

# Prompt for the client hopping interval immediately before the internal port.
eval "$(declare -f prompt_hy2_internal_port | sed '1s/^prompt_hy2_internal_port/original_prompt_hy2_internal_port/')"
prompt_hy2_internal_port() {
  local __var=$1 range=$2
  prompt_hy2_hop_interval HY2_SELECTED_HOP_INTERVAL 30 || return 1
  original_prompt_hy2_internal_port "$__var" "$range"
}

# Extend the hopping metadata with the intended client interval.
hy2_hop_meta_set() {
  local tag=$1 range=$2 interval=${3:-30s} tmp seconds
  validate_hy2_hop_range "$range" || die "无效的 Hysteria2 跳跃端口范围：${range}"
  seconds=${interval%s}
  validate_hy2_hop_interval_seconds "$seconds" || die "无效的 Hysteria2 跳跃时间间隔：${interval}"
  init_meta
  tmp=$(temp_file)
  jq --arg tag "$tag" --arg range "$range" --arg interval "$interval" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
    .inbounds[$tag]=((.inbounds[$tag]//{})+{updatedAt:$now}) |
    .inbounds[$tag].hysteria2PortHopping={enabled:true,range:$range,interval:$interval}' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"
  rm -f "$tmp"
}

# Override interactive reconfiguration so range and interval are edited together.
hy2_hop_configure() {
  local tag=$1 initial=${2:-0} type choice range current interval current_interval default_seconds
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
  [[ $type == hysteria2 ]] || die "只有 Hysteria2 入站支持端口跳跃。"
  current=$(hy2_hop_range_for_tag "$tag")
  current_interval=$(hy2_hop_interval_for_tag "$tag")
  default_seconds=${current_interval%s}
  validate_hy2_hop_interval_seconds "$default_seconds" || default_seconds=30

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
    hy2_hop_check_conflicts "$tag" "$range" || { warn "请换一个不冲突的端口范围。"; continue; }
    break
  done
  prompt_hy2_hop_interval interval "$default_seconds" || return 1
  warn "该范围内的入站 UDP 流量会被重定向到 ${tag}；请勿覆盖其他 UDP 服务使用的端口。"
  hy2_hop_meta_set "$tag" "$range" "$interval"
  if ! hy2_hop_sync; then
    warn "端口跳跃规则应用失败，正在回滚。"
    hy2_hop_meta_disable "$tag"
    hy2_hop_sync >/dev/null 2>&1 || true
    return 1
  fi
  info "Hysteria2 端口跳跃已启用：${range}，间隔 ${interval} -> UDP $(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen_port' "$CONFIG_FILE")"
}

# Final creation hook: persist both the selected range and interval.
add_inbound() {
  ensure_dependencies inbound-add; require_supported_core; ensure_config
  local inbound host public tag tmp type hop_range="" hop_interval=""
  HY2_SELECTED_HOP_INTERVAL=""
  build_inbound inbound host public hop_range
  hop_interval=$HY2_SELECTED_HOP_INTERVAL
  tag=$(jq -r '.tag' <<<"$inbound")
  type=$(jq -r '.type' <<<"$inbound")
  tmp=$(temp_file)
  jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then
    meta_set_inbound "$tag" "$host" "$public"
    if [[ $type == hysteria2 && -n $hop_range ]]; then
      [[ -n $hop_interval ]] || hop_interval=30s
      hy2_hop_meta_set "$tag" "$hop_range" "$hop_interval"
      if hy2_hop_sync; then
        info "Hysteria2 端口跳跃已启用：${hop_range}，间隔 ${hop_interval} -> UDP $(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen_port' "$CONFIG_FILE")"
      else
        warn "端口跳跃规则应用失败，已保留 Hysteria2 入站并关闭端口跳跃。"
        hy2_hop_meta_disable "$tag"
        hy2_hop_sync >/dev/null 2>&1 || true
      fi
    fi
    heading "入站已创建"
    show_inbound "$tag"
    print_share "$tag" "" || true
  fi
  rm -f "$tmp"
}

# Preserve the current share implementation and add interval information for HY2.
eval "$(declare -f print_share | sed '1s/^print_share/original_print_share_with_hop_range/')"
print_share() {
  ensure_config
  local tag=${1-} filter=${2-} type host share_host port share_port name password sni obfs obfs_password link interval range
  [[ -n $tag ]] || select_inbound tag || return
  inbound_exists "$tag" || die "找不到入站：$tag"
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
  [[ $type == hysteria2 ]] || { original_print_share_with_hop_range "$tag" "$filter"; return; }

  host=$(public_host_for_tag "$tag") || die "无法确定入站 ${tag} 的客户端连接地址。"
  share_host=$(uri_host "$host")
  port=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen_port' "$CONFIG_FILE")
  share_port=$(hy2_hop_client_port_spec "$tag" "$port")
  range=$(hy2_hop_range_for_tag "$tag")
  interval=$(hy2_hop_interval_for_tag "$tag")
  sni=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.tls.server_name' "$CONFIG_FILE")
  obfs=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.obfs.type // empty' "$CONFIG_FILE")
  obfs_password=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.obfs.password // empty' "$CONFIG_FILE")
  heading "${tag} 分享信息"
  while IFS=$'\t' read -r name password; do
    [[ -z $filter || $name == "$filter" ]] || continue
    link="hysteria2://$(url_encode "$password")@${share_host}:${share_port}?sni=$(url_encode "$sni")"
    [[ -z $obfs ]] || link+="&obfs=$(url_encode "$obfs")&obfs-password=$(url_encode "$obfs_password")"
    link+="#$(url_encode "${tag}-${name}")"
    print_share_entry "$name" "链接" "$link"
    if [[ -n $range ]]; then
      printf '跳跃间隔: %s\n' "${interval:-30s}"
      printf '提示: 标准 hysteria2:// URI 不携带跳跃间隔；客户端未单独设置时通常使用 30s。\n'
    fi
  done < <(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.users[]|[.name,.password]|@tsv' "$CONFIG_FILE")
  share_separator
}
