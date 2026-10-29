# shellcheck shell=bash
# sbctl state — config/meta lifecycle, migrations, transactions, backup and restore.

# ---- config bootstrap ----
ensure_config() {
  [[ -f $CONFIG_FILE ]] || write_default_config
  jq -e 'type=="object" and (.inbounds|type=="array") and (.outbounds|type=="array")' "$CONFIG_FILE" >/dev/null || die "配置不是有效的 sing-box JSON：$CONFIG_FILE"
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
  init_meta
  if [[ ${SBCTL_TAG_MIGRATION:-0} != 1 ]] && _config_has_missing_tags; then
    error "配置含未命名入站或出站；请先运行 sbctl config migrate-tags。"
    return 1
  fi
  validate_candidate "$candidate" || return 1
  if [[ -n $meta_candidate ]]; then
    validate_metadata_candidate "$meta_candidate" \
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
  require_root config migrate-tags
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
  mkdir -p "$BACKUP_DIR" || { rm -f "$work"; return 1; }
  backup=$(mktemp "${BACKUP_DIR}/pre-tag-migration-$(timestamp)-XXXXXX.json") || { rm -f "$work"; return 1; }
  if ! cp -a "$CONFIG_FILE" "$backup"; then
    rm -f "$work" "$backup"
    error "无法备份旧配置，标签迁移已取消。"
    return 1
  fi
  chmod 600 "$backup" 2>/dev/null || true
  if ! SBCTL_TAG_MIGRATION=1 apply_candidate "$work"; then
    rm -f "$work"
    error "标签迁移失败；原配置备份：${backup}"
    return 1
  fi
  rm -f "$work"
  info "已补全 ${changed} 个标签；原配置备份：${backup}"
}

# ---- backup and restore ----
backup_all() {
  require_root backup; ensure_config; init_meta
  local target=${1:-${BACKUP_DIR}/sbctl-$(timestamp).tar.gz} paths=("${CONFIG_FILE#/}" "${META_FILE#/}")
  traffic_is_enabled && traffic_collect || true
  if [[ ! -e $BACKUP_DIR ]]; then
    mkdir -p "$BACKUP_DIR" || return 1
    : >"$BACKUP_DIR/.sbctl-owned" || return 1
  fi
  # Record ownership before archiving metadata so the backup is self-consistent.
  # Never claim an existing directory without our ownership marker.
  if [[ ! -L $BACKUP_DIR && -f $BACKUP_DIR/.sbctl-owned && ! -L $BACKUP_DIR/.sbctl-owned ]]; then
    meta_resource_register backupDir "$BACKUP_DIR" || return 1
  fi
  mkdir -p "$(dirname "$target")" || return 1
  [[ ! -d $CERT_DIR ]] || paths+=("${CERT_DIR#/}")
  [[ ! -f $TRAFFIC_FILE ]] || paths+=("${TRAFFIC_FILE#/}")
  tar -czf "$target" -C / "${paths[@]}" || { rm -f "$target"; die "备份失败。"; }
  chmod 600 "$target" || return 1
  info "备份已创建：$target"
  info "提示：备份包含配置、metadata、流量记录和证书副本，不包含 Certbot 账户/lineage 数据。"
}

restore_backup() {
  ensure_dependencies restore; ensure_config
  local archive=${1-} temp extract_config snapshot had_meta=0 had_certs=0 had_traffic=0 restored_traffic=0
  [[ -n $archive ]] || prompt_value archive "备份文件路径"
  [[ -r $archive ]] || die "无法读取备份。"
  tar -tzf "$archive" >/dev/null || { warn "不是有效的 tar.gz 备份。"; return 1; }
  # Reject links and special files before extraction, including hard links.
  if ! LC_ALL=C tar -tvzf "$archive" | awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {bad=1} END{exit bad}'; then
    die "备份包含链接或特殊文件。"
  fi
  if tar -tzf "$archive" | awk 'BEGIN{bad=0} /^\// || /(^|\/)\.\.($|\/)/ {bad=1} END{exit !bad}'; then die "备份包含不安全路径。"; fi
  extract_config="${CONFIG_FILE#/}"; temp=$(mktemp -d "${TMPDIR:-/tmp}/sbctl-restore.XXXXXX")
  tar -xzf "$archive" -C "$temp" || { rm -rf "$temp"; die "备份解包失败。"; }
  [[ -f $temp/$extract_config ]] || { rm -rf "$temp"; die "备份中没有配置文件。"; }
  validate_candidate "$temp/$extract_config" || { rm -rf "$temp"; die "备份配置验证失败。"; }
  if [[ -f $temp/${META_FILE#/} ]] && ! validate_metadata_candidate "$temp/${META_FILE#/}"; then
    rm -rf "$temp"; die "备份 metadata 无效。"
  fi
  if [[ -f $temp/${TRAFFIC_FILE#/} ]] && ! jq -e 'type=="object" and ((.inbounds // {})|type)=="object"' "$temp/${TRAFFIC_FILE#/}" >/dev/null 2>&1; then
    rm -rf "$temp"; die "备份流量记录无效。"
  fi
  confirm "恢复会覆盖当前配置、元数据和托管证书，继续？" N || { rm -rf "$temp"; return; }
  if traffic_is_enabled; then traffic_collect || true; traffic_runtime_stop || { rm -rf "$temp"; return 1; }; fi
  snapshot="$temp/.current"; mkdir -p "$snapshot"; cp -a "$CONFIG_FILE" "$snapshot/config.json"
  [[ ! -f $META_FILE ]] || { cp -a "$META_FILE" "$snapshot/meta.json"; had_meta=1; }
  [[ ! -d $CERT_DIR ]] || { cp -a "$CERT_DIR" "$snapshot/certs"; had_certs=1; }
  [[ ! -f $TRAFFIC_FILE ]] || { cp -a "$TRAFFIC_FILE" "$snapshot/traffic.json"; had_traffic=1; }
  if ! {
    cp -a "$temp/$extract_config" "$CONFIG_FILE" &&
    { if [[ -f $temp/${META_FILE#/} ]]; then
        # Resource ownership belongs to this installation, not the machine
        # that produced the archive. Keep current records even for old backups.
        if ((had_meta)); then
          jq --slurpfile current "$snapshot/meta.json" \
            '$current[0] as $local | .managedResources=($local.managedResources // {}) |
             if ($local|has("singBox")) then .singBox=$local.singBox else del(.singBox) end' \
            "$temp/${META_FILE#/}" >"$temp/restored-meta.json" &&
            install -m 600 "$temp/restored-meta.json" "$META_FILE"
        else
          jq '.managedResources={} | del(.singBox)' "$temp/${META_FILE#/}" >"$temp/restored-meta.json" &&
            install -m 600 "$temp/restored-meta.json" "$META_FILE"
        fi
      elif ((had_meta)); then
        jq '{schema:2,inbounds:{},certificates:{},managedResources:(.managedResources // {}),migrations:{}} +
            (if has("singBox") then {singBox:.singBox} else {} end)' \
          "$snapshot/meta.json" >"$temp/restored-meta.json" && install -m 600 "$temp/restored-meta.json" "$META_FILE"
      else rm -f "$META_FILE"; fi; } &&
    (init_meta) && rm -rf "$CERT_DIR" && mkdir -p "$CERT_DIR" &&
    { [[ ! -d $temp/${CERT_DIR#/} ]] || cp -a "$temp/${CERT_DIR#/}/." "$CERT_DIR/"; } &&
    { if [[ -f $temp/${TRAFFIC_FILE#/} ]]; then
      restored_traffic=1; mkdir -p "$(dirname "$TRAFFIC_FILE")" && install -m 600 "$temp/${TRAFFIC_FILE#/}" "$TRAFFIC_FILE"
    fi; } &&
    restart_service_checked && hy2_hop_sync && traffic_runtime_ensure
  }; then
    error "恢复后服务、端口跳跃或流量统计运行时失败，正在整体回滚。"
    cp -a "$snapshot/config.json" "$CONFIG_FILE"
    ((had_meta)) && cp -a "$snapshot/meta.json" "$META_FILE" || rm -f "$META_FILE"
    init_meta; rm -rf "$CERT_DIR"; mkdir -p "$CERT_DIR"
    ((had_certs)) && cp -a "$snapshot/certs/." "$CERT_DIR/" || true
    if ((had_traffic)); then install -m 600 "$snapshot/traffic.json" "$TRAFFIC_FILE"; elif ((restored_traffic)); then rm -f "$TRAFFIC_FILE"; fi
    restart_service_checked || true
    hy2_hop_sync || true
    traffic_runtime_ensure || true
    rm -rf "$temp"; die "恢复失败，已回滚 config/meta/certs/traffic 和相关运行时规则。"
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

validate_metadata_candidate() {
  jq -e '
    type=="object" and
    ((.inbounds // {})|type)=="object" and
    ((.certificates // {})|type)=="object" and
    ((.managedResources // {})|type)=="object" and
    ((.migrations // {})|type)=="object" and
    ((.domainTemplates // {templates:[],bindings:[]})|type)=="object" and
    ((.domainTemplates.templates // [])|type)=="array" and
    ((.domainTemplates.bindings // [])|type)=="array" and
    ((.domainTemplates.managed // [])|type)=="array"
  ' "$1" >/dev/null 2>&1
}

commit_metadata_mutation() {
  local mutator=$1 candidate rc=0
  shift
  init_meta
  candidate=$(temp_file)
  "$mutator" "$META_FILE" "$candidate" "$@" || { rm -f "$candidate"; return 1; }
  commit_metadata_candidate "$candidate" || rc=$?
  rm -f "$candidate"
  return "$rc"
}

commit_metadata_candidate() {
  local candidate=$1 snapshot rc=0
  init_meta
  validate_metadata_candidate "$candidate" || { error "metadata 候选文件无效。"; return 1; }
  snapshot=$(temp_file)
  cp -a "$META_FILE" "$snapshot"
  if ! install -m 600 "$candidate" "$META_FILE"; then
    install -m 600 "$snapshot" "$META_FILE" || true
    rc=1
  fi
  rm -f "$snapshot"
  return "$rc"
}

_sbctl_meta_default_json() {
  printf '%s\n' '{"schema":2,"inbounds":{},"certificates":{},"managedResources":{},"migrations":{},"domainTemplates":{"templates":[],"bindings":[],"managed":[]}}'
}

_sbctl_meta_upgrade_file() {
  local tmp
  tmp=$(temp_file)
  jq '
    .schema=2 |
    .inbounds=(if (.inbounds|type)=="object" then .inbounds else {} end) |
    .certificates=(if (.certificates|type)=="object" then .certificates else {} end) |
    .managedResources=(if (.managedResources|type)=="object" then .managedResources else {} end) |
    .migrations=(if (.migrations|type)=="object" then .migrations else {} end) |
    .domainTemplates=(if (.domainTemplates|type)=="object" then .domainTemplates else {templates:[],bindings:[]} end) |
    .domainTemplates.templates=(if (.domainTemplates.templates|type)=="array" then .domainTemplates.templates else [] end) |
    .domainTemplates.bindings=(if (.domainTemplates.bindings|type)=="array" then .domainTemplates.bindings else [] end) |
    .domainTemplates.managed=(if (.domainTemplates.managed|type)=="array" then .domainTemplates.managed else [] end)
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
  host=$(jq -r --arg tag "$tag" '.inbounds[$tag].host // empty' "$META_FILE" 2>/dev/null || true)
  if [[ -z $host ]]; then
    prompt_public_host host || { error "入站 ${tag} 缺少客户端连接地址；请在交互模式下修改入站并补填。"; return 1; }
  fi
  printf '%s' "$host"
}
