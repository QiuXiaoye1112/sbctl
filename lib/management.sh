# shellcheck shell=bash
# sbctl misc management — client rename, batch share, BBR toggle, quick-command repair.
# Canonical CRUD and state functions live in inbound.sh, cache.sh, engine.sh, and system_guard.sh.

rename_client() {
  ensure_dependencies client-rename; ensure_config
  local tag=${1-} old=${2-} new=${3-} type field tmp
  [[ -n $tag ]] || select_inbound tag || return 0
  inbound_exists "$tag" || die "找不到入站：$tag"
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
  field=$(client_label_field "$type")
  if [[ -z $old ]]; then list_clients "$tag"; select_client old "$tag" || return 0; fi
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

bbr_state_summary() {
  if [[ -r /proc/sys/net/ipv4/tcp_congestion_control ]]; then
    [[ $(< /proc/sys/net/ipv4/tcp_congestion_control) == bbr ]] && printf '已启用' || printf '未启用'
  else printf '不可用'; fi
}

toggle_bbr() {
  if [[ -r /proc/sys/net/ipv4/tcp_congestion_control ]] && [[ $(< /proc/sys/net/ipv4/tcp_congestion_control) == bbr ]]; then
    disable_bbr
  else
    enable_bbr
  fi
}

repair_quick_command() {
  ensure_dependencies quick-command
  install_quick_command
  [[ -x $QUICK_COMMAND ]] || die "快捷命令修复失败。"
  info "快捷命令已修复：${QUICK_SYMLINK}"
}
