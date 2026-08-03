# Final inbound creation hook for Hysteria2 port hopping.

add_inbound() {
  ensure_dependencies inbound-add; require_supported_core; ensure_config
  local inbound host public tag tmp type hop_range=""
  build_inbound inbound host public hop_range
  tag=$(jq -r '.tag' <<<"$inbound")
  type=$(jq -r '.type' <<<"$inbound")
  tmp=$(temp_file)
  jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" >"$tmp"
  if apply_candidate "$tmp"; then
    meta_set_inbound "$tag" "$host" "$public"
    if [[ $type == hysteria2 && -n $hop_range ]]; then
      hy2_hop_meta_set "$tag" "$hop_range"
      if hy2_hop_sync; then
        info "Hysteria2 端口跳跃已启用：${hop_range} -> UDP $(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen_port' "$CONFIG_FILE")"
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
