# shellcheck shell=bash
# Transactional config/metadata state management and route-reference safety.

apply_candidate_with_meta() {
  local candidate=$1 meta_candidate=${2:-} cfg_rollback meta_rollback old_active=0 had_meta=0 failed=0
  ensure_config
  validate_candidate "$candidate" || return 1
  if [[ -n $meta_candidate ]]; then
    jq -e 'type=="object" and ((.inbounds // {})|type=="object")' "$meta_candidate" >/dev/null \
      || { error "metadata 候选文件无效。"; return 1; }
  fi
  service_is_active && old_active=1
  cfg_rollback=$(temp_file)
  meta_rollback=$(temp_file)
  cp -a "$CONFIG_FILE" "$cfg_rollback"
  if [[ -f $META_FILE ]]; then cp -a "$META_FILE" "$meta_rollback"; had_meta=1; fi
  install -m 600 "$candidate" "$CONFIG_FILE" || failed=1
  if ((failed == 0)) && [[ -n $meta_candidate ]]; then install -m 600 "$meta_candidate" "$META_FILE" || failed=1; fi
  if ((failed == 0 && old_active)) && ! restart_service_checked; then failed=1; fi
  if ((failed)); then
    error "状态应用失败，正在回滚 config/meta。"
    install -m 600 "$cfg_rollback" "$CONFIG_FILE" || true
    if ((had_meta)); then install -m 600 "$meta_rollback" "$META_FILE" || true; else rm -f "$META_FILE"; fi
    if ((old_active)); then service_restart >/dev/null 2>&1 || true; fi
    rm -f "$cfg_rollback" "$meta_rollback"
    return 1
  fi
  rm -f "$cfg_rollback" "$meta_rollback"
  info "配置已应用。"
}

apply_candidate() { apply_candidate_with_meta "$1"; }

build_inbound_meta_candidate() {
  local tag=$1 host=$2 public_key=${3-} config_candidate=$4 output=$5 private="" private_sha=""
  init_meta
  if [[ -n $public_key ]]; then
    private=$(jq -r --arg tag "$tag" '.inbounds[]?|select(.tag==$tag)|.tls.reality.private_key // empty' "$config_candidate" 2>/dev/null || true)
    [[ -z $private ]] || private_sha=$(printf '%s' "$private" | openssl dgst -sha256 -r | awk '{print $1}')
  fi
  jq --arg tag "$tag" --arg host "$host" --arg public "$public_key" --arg privateSHA "$private_sha" \
     --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
    .inbounds[$tag]=((.inbounds[$tag]//{})+{host:$host,updatedAt:$now}) |
    if $public!="" and $privateSHA!="" then
      .inbounds[$tag].realityPublicKey=$public | .inbounds[$tag].realityPrivateSHA256=$privateSHA
    else
      del(.inbounds[$tag].realityPublicKey,.inbounds[$tag].realityPrivateSHA256)
    end' "$META_FILE" >"$output"
}

add_inbound() {
  ensure_dependencies inbound-add; require_supported_core; ensure_config
  local inbound host public tag tmp meta_tmp rc=0
  build_inbound inbound host public
  tag=$(jq -r '.tag' <<<"$inbound")
  tmp=$(temp_file); meta_tmp=$(temp_file)
  jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" >"$tmp"
  build_inbound_meta_candidate "$tag" "$host" "$public" "$tmp" "$meta_tmp"
  if apply_candidate_with_meta "$tmp" "$meta_tmp"; then
    heading "入站已创建"
    show_inbound "$tag"
    print_share "$tag" "" || true
  else
    rc=$?
  fi
  rm -f "$tmp" "$meta_tmp"
  return "$rc"
}

modify_inbound_basic() {
  ensure_dependencies inbound-modify; ensure_config
  local tag=${1-} listen port host public tmp meta_tmp rc=0
  [[ -n $tag ]] || select_inbound tag || return 0
  inbound_exists "$tag" || die "找不到入站：$tag"
  prompt_value listen "监听地址" "$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen // "0.0.0.0"' "$CONFIG_FILE")"
  prompt_port port "$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen_port' "$CONFIG_FILE")" "$tag"
  prompt_public_host host "$(public_host_for_tag "$tag")"
  public=$(jq -r --arg tag "$tag" '.inbounds[$tag].realityPublicKey // empty' "$META_FILE" 2>/dev/null || true)
  tmp=$(temp_file); meta_tmp=$(temp_file)
  jq --arg tag "$tag" --arg listen "$listen" --argjson port "$port" '(.inbounds[]|select(.tag==$tag)) |= (.listen=$listen | .listen_port=$port)' "$CONFIG_FILE" >"$tmp"
  build_inbound_meta_candidate "$tag" "$host" "$public" "$tmp" "$meta_tmp"
  apply_candidate_with_meta "$tmp" "$meta_tmp" || rc=$?
  rm -f "$tmp" "$meta_tmp"
  return "$rc"
}

modify_inbound_security() {
  ensure_dependencies inbound-security; require_supported_core; ensure_config
  local tag=${1-} type choice tls="" public="" tmp meta_tmp host rc=0
  [[ -n $tag ]] || select_inbound tag || return 0
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
  host=$(public_host_for_tag "$tag" || true)
  [[ -n $host ]] || prompt_public_host host
  tmp=$(temp_file); meta_tmp=$(temp_file)
  jq --arg tag "$tag" --argjson tls "$tls" --arg type "$type" '
    (.inbounds[]|select(.tag==$tag)|.tls)=$tls |
    if $type=="vless" then
      (.inbounds[]|select(.tag==$tag)|.users) |= map(.flow=(if $tls.reality.enabled==true then "xtls-rprx-vision" else "" end))
    else . end' "$CONFIG_FILE" >"$tmp"
  build_inbound_meta_candidate "$tag" "$host" "$public" "$tmp" "$meta_tmp"
  if apply_candidate_with_meta "$tmp" "$meta_tmp"; then info "入站 ${tag} 的安全方式已更新。"; else rc=$?; fi
  rm -f "$tmp" "$meta_tmp"
  return "$rc"
}

rename_inbound() {
  ensure_dependencies inbound-rename; ensure_config
  local old=${1-} new=${2-} tmp meta_tmp rc=0
  [[ -n $old ]] || select_inbound old || return 0
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
  tmp=$(temp_file); meta_tmp=$(temp_file); init_meta
  jq --arg old "$old" --arg new "$new" '
    (.inbounds[]|select(.tag==$old)|.tag)=$new |
    .route.rules = [(.route.rules // [])[]? |
      if ((.inbound // null)|type)=="array" then
        .inbound |= map(if .==$old then $new else . end)
      elif (.inbound // null)==$old then .inbound=$new
      else . end]' "$CONFIG_FILE" >"$tmp"
  jq --arg old "$old" --arg new "$new" 'if .inbounds[$old] then .inbounds[$new]=.inbounds[$old] | del(.inbounds[$old]) else . end' "$META_FILE" >"$meta_tmp"
  if apply_candidate_with_meta "$tmp" "$meta_tmp"; then info "入站已重命名：${old} -> ${new}"; else rc=$?; fi
  rm -f "$tmp" "$meta_tmp"
  return "$rc"
}

delete_inbound() {
  ensure_dependencies inbound-delete; ensure_config
  local tag=${1-} yes=${2:-0} tmp meta_tmp rc=0
  [[ -n $tag ]] || select_inbound tag || return 0
  inbound_exists "$tag" || die "找不到入站：$tag"
  [[ $yes == 1 ]] || confirm "删除入站 ${tag}？" N || return
  tmp=$(temp_file); meta_tmp=$(temp_file); init_meta
  jq --arg tag "$tag" '
    .inbounds |= map(select(.tag!=$tag)) |
    .route.rules = [(.route.rules // [])[]? |
      if ((.inbound // null)|type)=="array" and ((.inbound // [])|index($tag))!=null then
        .inbound |= map(select(.!=$tag)) | select((.inbound|length)>0)
      elif (.inbound // null)==$tag then empty
      else . end]' "$CONFIG_FILE" >"$tmp"
  jq --arg tag "$tag" 'del(.inbounds[$tag])' "$META_FILE" >"$meta_tmp"
  if apply_candidate_with_meta "$tmp" "$meta_tmp"; then info "已删除入站 ${tag}。"; else rc=$?; fi
  rm -f "$tmp" "$meta_tmp"
  return "$rc"
}
