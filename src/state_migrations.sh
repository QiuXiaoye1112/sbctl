# Normalization helpers called from ensure_config (engine.sh).

_config_has_missing_tags() {
  jq -e '
    any(.inbounds[]?; ((.tag // "") | type != "string") or ((.tag // "") == "")) or
    any(.outbounds[]?; ((.tag // "") | type != "string") or ((.tag // "") == ""))
  ' "$CONFIG_FILE" >/dev/null 2>&1
}

_unique_config_tag() {
  local __var=$1 base=$2 candidate=$2 suffix=2
  while jq -e --arg tag "$candidate" '
    any(.inbounds[]?; (.tag // "") == $tag) or
    any(.outbounds[]?; (.tag // "") == $tag)
  ' "$3" >/dev/null 2>&1; do
    candidate="${base}-${suffix}"
    ((suffix+=1))
  done
  printf -v "$__var" '%s' "$candidate"
}

normalize_config_tags() {
  _config_has_missing_tags || return 0
  [[ -w $CONFIG_FILE ]] || die "检测到旧配置中存在未命名入站/出站；请使用 root 运行 sbctl 以自动兼容。"

  local work next backup idx type base generated changed=0
  work=$(temp_file)
  next=$(temp_file)
  cp -a "$CONFIG_FILE" "$work"

  while IFS=$'\t' read -r idx type; do
    [[ -n $idx ]] || continue
    type=${type:-inbound}
    base="legacy-${type}-$((idx+1))"
    _unique_config_tag generated "$base" "$work"
    jq --argjson idx "$idx" --arg tag "$generated" '.inbounds[$idx].tag=$tag' "$work" >"$next"
    mv -f "$next" "$work"
    next=$(temp_file)
    ((changed+=1))
  done < <(jq -r '.inbounds|to_entries[]|select(((.value.tag // "")|type)!="string" or ((.value.tag // "")==""))|[.key,(.value.type//"inbound")]|@tsv' "$work")

  while IFS=$'\t' read -r idx type; do
    [[ -n $idx ]] || continue
    type=${type:-outbound}
    case $type in
      direct|block|dns) base=$type ;;
      *) base="legacy-out-${type}-$((idx+1))" ;;
    esac
    _unique_config_tag generated "$base" "$work"
    jq --argjson idx "$idx" --arg tag "$generated" '.outbounds[$idx].tag=$tag' "$work" >"$next"
    mv -f "$next" "$work"
    next=$(temp_file)
    ((changed+=1))
  done < <(jq -r '.outbounds|to_entries[]|select(((.value.tag // "")|type)!="string" or ((.value.tag // "")==""))|[.key,(.value.type//"outbound")]|@tsv' "$work")

  rm -f "$next"
  ((changed > 0)) || { rm -f "$work"; return 0; }
  validate_candidate "$work" || { rm -f "$work"; die "旧配置补全标签后未通过 sing-box 检查，原配置未修改。"; }

  mkdir -p "$BACKUP_DIR"
  backup="${BACKUP_DIR}/pre-tag-migration-$(timestamp).json"
  cp -a "$CONFIG_FILE" "$backup"
  chmod 600 "$backup" 2>/dev/null || true
  install -m 600 "$work" "$CONFIG_FILE"
  rm -f "$work"
  warn "检测到旧配置缺少 tag，已自动补全 ${changed} 个标签；原配置备份：${backup}"
}
