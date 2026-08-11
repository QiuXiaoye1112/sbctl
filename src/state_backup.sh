# shellcheck shell=bash
# sbctl backup/restore operations — canonical implementations.

backup_all() {
  require_root backup; ensure_config
  local target=${1:-${BACKUP_DIR}/sbctl-$(timestamp).tar.gz} paths=("${CONFIG_FILE#/}" "${META_FILE#/}")
  mkdir -p "$BACKUP_DIR" "$(dirname "$target")"
  [[ ! -d $CERT_DIR ]] || paths+=("${CERT_DIR#/}")
  tar -czf "$target" -C / "${paths[@]}" || die "备份失败。"
  chmod 600 "$target"
  meta_resource_register backupDir "$BACKUP_DIR"
  info "备份已创建：$target"
  info "提示：备份包含配置、metadata 和证书副本，不包含 Certbot 账户/lineage 数据。"
}

restore_backup() {
  ensure_dependencies restore; ensure_config
  local archive=${1-} temp extract_config snapshot had_meta=0 had_certs=0
  [[ -n $archive ]] || prompt_value archive "备份文件路径"
  [[ -r $archive ]] || die "无法读取备份。"
  tar -tzf "$archive" >/dev/null || { warn "不是有效的 tar.gz 备份。"; return 0; }
  if tar -tzf "$archive" | awk 'BEGIN{bad=0} /^\// || /(^|\/)\.\.($|\/)/ {bad=1} END{exit !bad}'; then die "备份包含不安全路径。"; fi
  extract_config="${CONFIG_FILE#/}"
  temp=$(mktemp -d "${TMPDIR:-/tmp}/sbctl-restore.XXXXXX")
  tar -xzf "$archive" -C "$temp"
  [[ -f $temp/$extract_config ]] || { rm -rf "$temp"; die "备份中没有配置文件。"; }
  validate_candidate "$temp/$extract_config" || { rm -rf "$temp"; die "备份配置验证失败。"; }
  confirm "恢复会覆盖当前配置、元数据和托管证书，继续？" N || { rm -rf "$temp"; return; }
  snapshot="$temp/.current"; mkdir -p "$snapshot"
  cp -a "$CONFIG_FILE" "$snapshot/config.json"
  [[ ! -f $META_FILE ]] || { cp -a "$META_FILE" "$snapshot/meta.json"; had_meta=1; }
  [[ ! -d $CERT_DIR ]] || { cp -a "$CERT_DIR" "$snapshot/certs"; had_certs=1; }
  cp -a "$temp/$extract_config" "$CONFIG_FILE"
  if [[ -f $temp/${META_FILE#/} ]]; then cp -a "$temp/${META_FILE#/}" "$META_FILE"; else rm -f "$META_FILE"; fi
  init_meta
  rm -rf "$CERT_DIR"; mkdir -p "$CERT_DIR"
  [[ ! -d $temp/${CERT_DIR#/} ]] || cp -a "$temp/${CERT_DIR#/}/." "$CERT_DIR/"
  if ! restart_service_checked; then
    error "恢复后服务失败，正在整体回滚。"
    cp -a "$snapshot/config.json" "$CONFIG_FILE"
    ((had_meta)) && cp -a "$snapshot/meta.json" "$META_FILE" || rm -f "$META_FILE"
    init_meta
    rm -rf "$CERT_DIR"; mkdir -p "$CERT_DIR"
    ((had_certs)) && cp -a "$snapshot/certs/." "$CERT_DIR/" || true
    restart_service_checked || true
    rm -rf "$temp"
    die "恢复失败，已回滚 config/meta/certs。"
  fi
  # Post-restore: warn about missing Certbot lineages (from enhancements.sh)
  local id source auto_renew cert_name warned=0
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    source=$(meta_cert_get_field "$id" source)
    auto_renew=$(meta_cert_get_field "$id" autoRenew)
    [[ $source == letsencrypt && $auto_renew == true ]] || continue
    cert_name=$(meta_cert_get_field "$id" certName)
    if [[ -z $cert_name || ! -d $CERTBOT_CONFIG_DIR/live/$cert_name ]]; then
      warn "证书 ${id}: 副本已恢复，但 Certbot lineage 缺失，无法自动续期；请重新签发。"
      ((warned+=1))
    fi
  done < <(meta_cert_list)
  ((warned == 0)) || warn "共 ${warned} 张自动证书缺少 Certbot 续期数据。"
  rm -rf "$temp"
  info "备份已恢复。"
}
