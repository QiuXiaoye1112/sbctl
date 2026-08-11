# shellcheck shell=bash
# sbctl state — config/meta lifecycle, migrations, transactions, backup and restore.

# ---- config bootstrap ----
ensure_config() {
  [[ -f $CONFIG_FILE ]] || write_default_config
  jq -e 'type=="object" and (.inbounds|type=="array") and (.outbounds|type=="array")' "$CONFIG_FILE" >/dev/null || die "配置不是有效的 sing-box JSON：$CONFIG_FILE"
  normalize_config_tags
  jq -e '
    all(.inbounds[]?; ((.tag // "")|type)=="string" and ((.tag // "")!="")) and
    all(.outbounds[]?; ((.tag // "")|type)=="string" and ((.tag // "")!=""))
  ' "$CONFIG_FILE" >/dev/null || die "配置中的入站/出站标签仍不完整。"
  init_meta
}

write_default_config() {
  mkdir -p "$CONFIG_DIR" "$CERT_DIR" "$(dirname "$META_FILE")"
  cat >"$CONFIG_FILE" <<'JSON'
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct"
  }
}
JSON
  chmod 600 "$CONFIG_FILE"
  init_meta
}

validate_candidate() {
  local candidate=$1 output
  jq -e 'type=="object" and (.inbounds|type=="array") and (.outbounds|type=="array")' "$candidate" >/dev/null || { error "JSON 结构检查失败。"; return 1; }
  if sing_box_installed; then
    refresh_binary_path
    if ! output=$("$SING_BOX_BIN" check -c "$candidate" 2>&1); then
      error "sing-box 拒绝了新配置："
      printf '%s\n' "$output" >&2
      return 1
    fi
  fi
}

# Transactional config+meta apply.
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

# Config-only convenience API.
apply_candidate() { apply_candidate_with_meta "$1"; }

# Metadata candidate builder.
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

check_config() { ensure_config; require_supported_core; validate_candidate "$CONFIG_FILE" && info "配置检查通过。"; }

edit_config() {
  ensure_dependencies config-edit; ensure_config
  local editor=${EDITOR:-vi} tmp
  tmp=$(temp_file); cp -a "$CONFIG_FILE" "$tmp"
  "$editor" "$tmp"
  if cmp -s "$tmp" "$CONFIG_FILE"; then info "配置未更改。"; else apply_candidate "$tmp"; fi
  rm -f "$tmp"
}

# ---- idempotent config migrations ----
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
    candidate="${base}-${suffix}"; ((suffix+=1))
  done
  printf -v "$__var" '%s' "$candidate"
}

normalize_config_tags() {
  _config_has_missing_tags || return 0
  [[ -w $CONFIG_FILE ]] || die "检测到旧配置中存在未命名入站/出站；请使用 root 运行 sbctl 以自动兼容。"
  local work next backup idx type base generated changed=0
  work=$(temp_file); next=$(temp_file); cp -a "$CONFIG_FILE" "$work"
  while IFS=$'\t' read -r idx type; do
    [[ -n $idx ]] || continue
    type=${type:-inbound}; base="legacy-${type}-$((idx+1))"
    _unique_config_tag generated "$base" "$work"
    jq --argjson idx "$idx" --arg tag "$generated" '.inbounds[$idx].tag=$tag' "$work" >"$next"
    mv -f "$next" "$work"; next=$(temp_file); ((changed+=1))
  done < <(jq -r '.inbounds|to_entries[]|select(((.value.tag // "")|type)!="string" or ((.value.tag // "")==""))|[.key,(.value.type//"inbound")]|@tsv' "$work")
  while IFS=$'\t' read -r idx type; do
    [[ -n $idx ]] || continue
    type=${type:-outbound}
    case $type in direct|block|dns) base=$type;; *) base="legacy-out-${type}-$((idx+1))";; esac
    _unique_config_tag generated "$base" "$work"
    jq --argjson idx "$idx" --arg tag "$generated" '.outbounds[$idx].tag=$tag' "$work" >"$next"
    mv -f "$next" "$work"; next=$(temp_file); ((changed+=1))
  done < <(jq -r '.outbounds|to_entries[]|select(((.value.tag // "")|type)!="string" or ((.value.tag // "")==""))|[.key,(.value.type//"outbound")]|@tsv' "$work")
  rm -f "$next"
  ((changed > 0)) || { rm -f "$work"; return 0; }
  validate_candidate "$work" || { rm -f "$work"; die "旧配置补全标签后未通过 sing-box 检查，原配置未修改。"; }
  mkdir -p "$BACKUP_DIR"; backup="${BACKUP_DIR}/pre-tag-migration-$(timestamp).json"
  cp -a "$CONFIG_FILE" "$backup"; chmod 600 "$backup" 2>/dev/null || true
  install -m 600 "$work" "$CONFIG_FILE"; rm -f "$work"
  warn "检测到旧配置缺少 tag，已自动补全 ${changed} 个标签；原配置备份：${backup}"
}

# ---- backup and restore ----
backup_all() {
  require_root backup; ensure_config
  local target=${1:-${BACKUP_DIR}/sbctl-$(timestamp).tar.gz} paths=("${CONFIG_FILE#/}" "${META_FILE#/}")
  mkdir -p "$BACKUP_DIR" "$(dirname "$target")"
  [[ ! -d $CERT_DIR ]] || paths+=("${CERT_DIR#/}")
  tar -czf "$target" -C / "${paths[@]}" || die "备份失败。"
  chmod 600 "$target"; meta_resource_register backupDir "$BACKUP_DIR"
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
  extract_config="${CONFIG_FILE#/}"; temp=$(mktemp -d "${TMPDIR:-/tmp}/sbctl-restore.XXXXXX")
  tar -xzf "$archive" -C "$temp"
  [[ -f $temp/$extract_config ]] || { rm -rf "$temp"; die "备份中没有配置文件。"; }
  validate_candidate "$temp/$extract_config" || { rm -rf "$temp"; die "备份配置验证失败。"; }
  confirm "恢复会覆盖当前配置、元数据和托管证书，继续？" N || { rm -rf "$temp"; return; }
  snapshot="$temp/.current"; mkdir -p "$snapshot"; cp -a "$CONFIG_FILE" "$snapshot/config.json"
  [[ ! -f $META_FILE ]] || { cp -a "$META_FILE" "$snapshot/meta.json"; had_meta=1; }
  [[ ! -d $CERT_DIR ]] || { cp -a "$CERT_DIR" "$snapshot/certs"; had_certs=1; }
  cp -a "$temp/$extract_config" "$CONFIG_FILE"
  if [[ -f $temp/${META_FILE#/} ]]; then cp -a "$temp/${META_FILE#/}" "$META_FILE"; else rm -f "$META_FILE"; fi
  init_meta; rm -rf "$CERT_DIR"; mkdir -p "$CERT_DIR"
  [[ ! -d $temp/${CERT_DIR#/} ]] || cp -a "$temp/${CERT_DIR#/}/." "$CERT_DIR/"
  if ! restart_service_checked; then
    error "恢复后服务失败，正在整体回滚。"
    cp -a "$snapshot/config.json" "$CONFIG_FILE"
    ((had_meta)) && cp -a "$snapshot/meta.json" "$META_FILE" || rm -f "$META_FILE"
    init_meta; rm -rf "$CERT_DIR"; mkdir -p "$CERT_DIR"
    ((had_certs)) && cp -a "$snapshot/certs/." "$CERT_DIR/" || true
    restart_service_checked || true; rm -rf "$temp"; die "恢复失败，已回滚 config/meta/certs。"
  fi
  local id source auto_renew cert_name warned=0
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    source=$(meta_cert_get_field "$id" source); auto_renew=$(meta_cert_get_field "$id" autoRenew)
    [[ $source == letsencrypt && $auto_renew == true ]] || continue
    cert_name=$(meta_cert_get_field "$id" certName)
    if [[ -z $cert_name || ! -d $CERTBOT_CONFIG_DIR/live/$cert_name ]]; then
      warn "证书 ${id}: 副本已恢复，但 Certbot lineage 缺失，无法自动续期；请重新签发。"; ((warned+=1))
    fi
  done < <(meta_cert_list)
  ((warned == 0)) || warn "共 ${warned} 张自动证书缺少 Certbot 续期数据。"
  rm -rf "$temp"; info "备份已恢复。"
}


# ---- metadata primitives ----
init_meta() {
  mkdir -p "$(dirname "$META_FILE")"
  if [[ ! -s $META_FILE ]] || ! jq -e 'type=="object" and ((.inbounds // {})|type=="object")' "$META_FILE" >/dev/null 2>&1; then
    [[ ! -f $META_FILE ]] || cp -a "$META_FILE" "${META_FILE}.broken-$(timestamp)"
    _sbctl_meta_default_json >"$META_FILE"
    chmod 600 "$META_FILE"
  else
    _sbctl_meta_upgrade_file || die "无法升级 sbctl metadata。"
  fi
  _sbctl_meta_legacy_cert_scan
}

_sbctl_meta_default_json() {
  printf '%s\n' '{"schema":2,"inbounds":{},"certificates":{},"managedResources":{},"migrations":{}}'
}

_sbctl_meta_upgrade_file() {
  local tmp
  tmp=$(temp_file)
  jq '
    .schema=2 |
    .inbounds=(if (.inbounds|type)=="object" then .inbounds else {} end) |
    .certificates=(if (.certificates|type)=="object" then .certificates else {} end) |
    .managedResources=(if (.managedResources|type)=="object" then .managedResources else {} end) |
    .migrations=(if (.migrations|type)=="object" then .migrations else {} end)
  ' "$META_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
  install -m 600 "$tmp" "$META_FILE"
  rm -f "$tmp"
}

_sbctl_meta_legacy_cert_scan() {
  jq -e '.migrations.legacyCertScanV1 == true' "$META_FILE" >/dev/null 2>&1 && return 0
  local cert key id subject tmp migrated=0
  mkdir -p "$CERT_DIR"
  for cert in "$CERT_DIR"/*.crt; do
    [[ -r $cert ]] || continue
    key=${cert%.crt}.key
    [[ -r $key ]] || continue
    id=$(basename "$cert" .crt)
    jq -e --arg id "$id" '.certificates[$id] != null' "$META_FILE" >/dev/null 2>&1 && continue
    subject=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null \
      | sed -n 's/.*DNS:\([^, ]*\).*/\1/p' | head -1 || true)
    if [[ -z $subject ]]; then
      subject=$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253 2>/dev/null \
        | sed -n 's/^subject=.*CN=\([^,]*\).*$/\1/p' | head -1 || true)
    fi
    [[ -n $subject ]] || subject=$id
    tmp=$(temp_file)
    jq --arg id "$id" --arg subject "$subject" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
      .certificates[$id]={subject:$subject,certName:$id,source:"legacy",validation:"legacy",autoRenew:false,updatedAt:$now}
    ' "$META_FILE" >"$tmp"
    install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
    ((migrated+=1))
  done
  tmp=$(temp_file)
  jq '.migrations.legacyCertScanV1=true' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
  ((migrated == 0)) || info "已将 ${migrated} 张旧版证书登记到 sbctl metadata。"
}

meta_set_inbound() {
  local tag=$1 host=$2 public_key=${3-} tmp private private_sha=""
  init_meta
  if [[ -n $public_key && -f $CONFIG_FILE ]]; then
    private=$(jq -r --arg tag "$tag" '.inbounds[]?|select(.tag==$tag)|.tls.reality.private_key // empty' "$CONFIG_FILE" 2>/dev/null || true)
    [[ -z $private ]] || private_sha=$(printf '%s' "$private" | openssl dgst -sha256 -r | awk '{print $1}')
  fi
  tmp=$(temp_file)
  jq --arg tag "$tag" --arg host "$host" --arg public "$public_key" --arg privateSHA "$private_sha" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
    .inbounds[$tag]=((.inbounds[$tag]//{})+{host:$host,updatedAt:$now}) |
    if $public!="" and $privateSHA!="" then
      .inbounds[$tag].realityPublicKey=$public | .inbounds[$tag].realityPrivateSHA256=$privateSHA
    else
      del(.inbounds[$tag].realityPublicKey,.inbounds[$tag].realityPrivateSHA256)
    end' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
}
meta_set_host() {
  local tag=$1 host=$2 tmp
  init_meta; tmp=$(temp_file)
  jq --arg tag "$tag" --arg host "$host" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
    .inbounds[$tag]=((.inbounds[$tag]//{})+{host:$host,updatedAt:$now})' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
}
public_host_for_tag() {
  local tag=$1 host=""
  init_meta
  host=$(jq -r --arg tag "$tag" '.inbounds[$tag].host // empty' "$META_FILE")
  if [[ -z $host ]]; then
    prompt_public_host host || { error "入站 ${tag} 缺少客户端连接地址；请在交互模式下修改入站并补填。"; return 1; }
    meta_set_host "$tag" "$host"
  fi
  printf '%s' "$host"
}
