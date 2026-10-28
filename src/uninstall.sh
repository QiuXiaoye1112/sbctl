# Complete removal and resource ownership safeguards.

cleanup_step() {
  local description=$1; shift
  printf '  %s ... ' "$description"
  if "$@"; then printf '✓\n'; return 0; else printf '✗\n'; return 1; fi
}

_uninstall_snapshot_metadata() {
  SNAPSHOT_META=$(temp_file)
  if [[ -f $META_FILE ]] && jq -e 'type=="object"' "$META_FILE" >/dev/null 2>&1; then cp -a "$META_FILE" "$SNAPSHOT_META"
  else printf '%s\n' '{"certificates":{},"managedResources":{}}' >"$SNAPSHOT_META"; fi
}

_snapshot_meta_cert_list() { jq -r '.certificates // {} | keys[]' "$SNAPSHOT_META" 2>/dev/null; }
_snapshot_meta_cert_get_field() { jq -r --arg id "$1" --arg field "$2" '.certificates[$id][$field] // empty' "$SNAPSHOT_META" 2>/dev/null; }
_snapshot_meta_resource_get() { jq -r --arg key "$1" '.managedResources[$key] // empty' "$SNAPSHOT_META" 2>/dev/null; }

_clear_sing_box_install_metadata() {
  [[ -f $META_FILE ]] || return 0
  local tmp
  tmp=$(temp_file)
  jq 'del(.singBox,
          .managedResources.singBoxInstallSource,
          .managedResources.singBoxBinaryPath,
          .managedResources.singBoxBinarySHA256)' "$META_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
  install -m 600 "$tmp" "$META_FILE"
  rm -f "$tmp"
}

_remove_managed_sing_box_release_binary() {
  local path expected_sha256 actual_sha256
  path=$(_sing_box_meta_get binary)
  expected_sha256=$(_sing_box_meta_get sha256)
  [[ $(_sing_box_meta_get managed) == true && $(_sing_box_meta_get source) == official-release ]] || {
    warn "sing-box metadata 未确认核心归 sbctl 管理，保留现有 binary。"
    return 1
  }
  [[ $path == "$SING_BOX_RELEASE_INSTALL_PATH" ]] || {
    warn "sing-box metadata 路径无效，保留现有 binary。"
    return 1
  }
  [[ $path == /usr/local/bin/sing-box || ${SBCTL_TESTING:-0} == 1 ]] || {
    warn "sing-box metadata 使用了非标准路径，保留现有 binary。"
    return 1
  }
  [[ -e $path || -L $path ]] || return 0
  if [[ ! -f $path || -L $path || -z $expected_sha256 ]]; then
    warn "无法确认 ${path} 仍是 sbctl 安装的 binary，已保留。"
    return 1
  fi
  actual_sha256=$(_sing_box_binary_sha256 "$path") || true
  if [[ -z $actual_sha256 || $actual_sha256 != "$expected_sha256" ]]; then
    warn "${path} 已被修改，无法确认归 sbctl 管理，已保留。"
    return 1
  fi
  rm -f -- "$path"
}

_safe_remove_sbctl_dir() {
  local path=$1 key=${2:-} recorded=""
  [[ -n $path && $path == /* ]] || return 1
  case $path in /|/etc|/usr|/usr/local|/var|/var/lib|/var/log|/opt|/home|/root) warn "拒绝删除危险路径：$path"; return 1;; esac
  [[ -z $key ]] || recorded=$(_snapshot_meta_resource_get "$key")
  [[ -n $recorded && $recorded == "$path" && ! -L $path ]] || { warn "未确认目录归 sbctl 所有，跳过：$path"; return 1; }
  [[ ! -e $path ]] || rm -rf -- "$path"
}

_remove_renewal_jobs() {
  case $(init_system) in
    systemd)
      if [[ -e ${SYSTEMD_UNIT_DIR}/sbctl-certbot-renew.timer ]]; then
        systemctl disable --now sbctl-certbot-renew.timer >/dev/null 2>&1 || return 1
      fi
      if [[ -e ${SYSTEMD_UNIT_DIR}/sbctl-certbot-renew.service ]]; then
        systemctl stop sbctl-certbot-renew.service >/dev/null 2>&1 || return 1
      fi
      rm -f "${SYSTEMD_UNIT_DIR}/sbctl-certbot-renew.service" "${SYSTEMD_UNIT_DIR}/sbctl-certbot-renew.timer" || return 1
      systemctl daemon-reload >/dev/null 2>&1 || return 1
      ;;
    openrc) rm -f /etc/periodic/daily/sbctl-certbot-renew;;
  esac
}

_remove_legacy_certbot_assets() {
  local hook name rc=0
  for hook in "$CERTBOT_HOOK_DIR"/sbctl-*; do
    [[ -e $hook ]] || continue
    name=$(basename "$hook"); name=${name#sbctl-}
    if [[ -n $name && -f /etc/letsencrypt/renewal/${name}.conf ]] && command_exists certbot; then
      certbot delete --cert-name "$name" --non-interactive >/dev/null 2>&1 || { warn "旧版 Certbot lineage 删除失败：$name"; rc=1; continue; }
    fi
    rm -f "$hook" || rc=1
  done
  return "$rc"
}

_remove_managed_certificates() {
  local id source cert_name rc=0
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    if ! validate_certificate_identifier "$id" || [[ $id == . || $id == .. ]]; then
      warn "无效证书标识，已保留：$id"; rc=1; continue
    fi
    source=$(_snapshot_meta_cert_get_field "$id" source); cert_name=$(_snapshot_meta_cert_get_field "$id" certName)
    if [[ $source == letsencrypt && -n $cert_name && -x $CERTBOT_BIN && -f $CERTBOT_CONFIG_DIR/renewal/${cert_name}.conf ]]; then
      certbot_cmd delete --cert-name "$cert_name" --non-interactive >/dev/null 2>&1 || { warn "Certbot lineage 删除失败：$cert_name"; rc=1; continue; }
    fi
    rm -f -- "$CERT_DIR/${id}.crt" "$CERT_DIR/${id}.key" || rc=1
  done < <(_snapshot_meta_cert_list)
  _remove_legacy_certbot_assets || rc=1
  return "$rc"
}

_remove_certbot_environment() {
  local path key rc=0
  for key in certbotConfigDir certbotWorkDir certbotLogsDir certbotVenv; do
    case $key in certbotConfigDir) path=$CERTBOT_CONFIG_DIR;; certbotWorkDir) path=$CERTBOT_WORK_DIR;; certbotLogsDir) path=$CERTBOT_LOGS_DIR;; certbotVenv) path=$CERTBOT_VENV;; esac
    [[ -e $path || -L $path ]] || continue
    _safe_remove_sbctl_dir "$path" "$key" || rc=1
  done
  rmdir /var/log/sbctl /opt/sbctl 2>/dev/null || true
  return "$rc"
}

_remove_sbctl_service_definition() {
  case $(init_system) in
    systemd)
      local unit="${SYSTEMD_UNIT_DIR}/${SERVICE_NAME}.service"
      if [[ -f $unit ]] && grep -q 'managed by sbctl' "$unit" 2>/dev/null; then rm -f "$unit" || return 1; fi
      systemctl daemon-reload >/dev/null 2>&1 || return 1
      ;;
    openrc)
      local init="${OPENRC_INIT_DIR}/${SERVICE_NAME}"
      if [[ -f $init ]] && grep -q 'managed by sbctl' "$init" 2>/dev/null; then rm -f "$init" || return 1; fi
      ;;
  esac
}

_sbctl_service_definition_is_managed() {
  local definition=""
  case $(init_system) in
    systemd) definition="${SYSTEMD_UNIT_DIR}/${SERVICE_NAME}.service" ;;
    openrc) definition="${OPENRC_INIT_DIR}/${SERVICE_NAME}" ;;
  esac
  [[ -f $definition ]] && grep -q 'managed by sbctl' "$definition" 2>/dev/null
}

_remove_sing_box_core() {
  local rc=0
  if ! _sing_box_target_is_managed; then
    warn "未确认 sing-box 核心归 sbctl 管理；不会删除任何 sing-box binary 或系统软件包。"
    if _sbctl_service_definition_is_managed; then
      service_stop >/dev/null 2>&1 || return 1
      service_disable >/dev/null 2>&1 || return 1
      _remove_sbctl_service_definition || return 1
    fi
    return 0
  fi
  service_stop >/dev/null 2>&1 || return 1
  service_disable >/dev/null 2>&1 || return 1
  _remove_managed_sing_box_release_binary || rc=1
  ((rc != 0)) || _clear_sing_box_install_metadata || rc=1
  _remove_sbctl_service_definition || rc=1
  return "$rc"
}

_remove_quick_command_and_libs() {
  local rc=0
  if [[ -L $QUICK_SYMLINK ]] && [[ $(readlink "$QUICK_SYMLINK" 2>/dev/null) == "$QUICK_COMMAND" ]]; then rm -f "$QUICK_SYMLINK" || rc=1; fi
  if [[ -f $QUICK_COMMAND ]] && grep -q '^# sbctl - sing-box Linux terminal manager' "$QUICK_COMMAND" 2>/dev/null; then rm -f "$QUICK_COMMAND" || rc=1; fi
  if [[ $LIB_DIR == /usr/local/lib/sbctl && -e $LIB_DIR ]]; then _safe_remove_sbctl_dir "$LIB_DIR" libDir || rc=1; fi
  hash -r 2>/dev/null || true
  return "$rc"
}

_remove_config_and_metadata() {
  if [[ -d $CERT_DIR ]]; then
    rmdir -- "$CERT_DIR" || { warn "证书目录非空，已保留：$CERT_DIR"; return 1; }
  fi
  if [[ -d $DATA_DIR ]] && [[ -n $(ls -A "$DATA_DIR" 2>/dev/null) ]]; then
    warn "数据目录非空，已保留配置和 metadata：$DATA_DIR"; return 1
  fi
  rm -f "$CONFIG_FILE" || return 1
  [[ ! -d $CONFIG_DIR ]] || rmdir "$CONFIG_DIR" 2>/dev/null || true
  rm -f "$META_FILE"
  rmdir "$(dirname "$META_FILE")" 2>/dev/null || true
  if [[ -d $DATA_DIR ]]; then
    local recorded_data
    recorded_data=$(_snapshot_meta_resource_get dataDir)
    if [[ -n $recorded_data && $recorded_data == "$DATA_DIR" ]]; then
      rmdir "$DATA_DIR" 2>/dev/null || { warn "数据目录非空，已保留：$DATA_DIR"; return 1; }
    else rmdir "$DATA_DIR" 2>/dev/null || true; fi
  fi
  rm -f /var/log/sing-box.log 2>/dev/null || true
}

_remove_bbr_settings() {
  local config=$SBCTL_BBR_CONFIG available fallback=""
  if [[ -f $XRAYCTL_BBR_CONFIG ]]; then
    if grep -q '^# managed by sbctl$' "$config" 2>/dev/null; then rm -f "$config"; fi
    info "检测到 xrayctl 管理 BBR；仅移除 sbctl 自有配置，保留全局 BBR。"
    return 0
  fi
  if ! grep -q '^# managed by sbctl$' "$config" 2>/dev/null; then
    info "BBR 不由 sbctl 管理；保留全局拥塞控制设置。"
    return 0
  fi
  if [[ -r /proc/sys/net/ipv4/tcp_congestion_control && $(< /proc/sys/net/ipv4/tcp_congestion_control) == bbr ]]; then
    available=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)
    if grep -qw cubic <<<"$available"; then fallback=cubic; elif grep -qw reno <<<"$available"; then fallback=reno; fi
    [[ -z $fallback ]] || sysctl -w net.ipv4.tcp_congestion_control="$fallback" >/dev/null 2>&1 || true
  fi
  rm -f "$config"
}

_remove_backups() {
  [[ -f $BACKUP_DIR/.sbctl-owned && ! -L $BACKUP_DIR && ! -L $BACKUP_DIR/.sbctl-owned ]] || { warn "备份目录没有 sbctl 所有权标记，已保留：$BACKUP_DIR"; return 1; }
  if [[ $(_snapshot_meta_resource_get backupDir) != "$BACKUP_DIR" ]]; then
    warn "备份目录未登记，已保留：$BACKUP_DIR"; return 1
  fi
  _safe_remove_sbctl_dir "$BACKUP_DIR" backupDir
}

_scan_sbctl_residuals() {
  local __count_var=$1 count=0 path
  local paths=("$QUICK_COMMAND" "$QUICK_SYMLINK" "$CONFIG_FILE" "$META_FILE" "$CERT_DIR" "$CERTBOT_VENV" "$CERTBOT_CONFIG_DIR" "$CERTBOT_WORK_DIR" "$CERTBOT_LOGS_DIR" \
    "$TRAFFIC_FILE" "$TRAFFIC_SYSTEMD_SERVICE" "$TRAFFIC_SYSTEMD_TIMER" "$TRAFFIC_OPENRC_SERVICE" \
    "${SYSTEMD_UNIT_DIR}/sbctl-certbot-renew.service" "${SYSTEMD_UNIT_DIR}/sbctl-certbot-renew.timer" /etc/periodic/daily/sbctl-certbot-renew)
  [[ $LIB_DIR != /usr/local/lib/sbctl ]] || paths+=("$LIB_DIR")
  paths+=("$BACKUP_DIR" /etc/sysctl.d/99-sbctl-bbr.conf)
  for path in "${paths[@]}"; do
    [[ ! -e $path && ! -L $path ]] || { printf '  ✗ 残留: %s\n' "$path"; ((count+=1)); }
  done
  for path in "$CERTBOT_HOOK_DIR"/sbctl-*; do [[ ! -e $path ]] || { printf '  ✗ 残留: %s\n' "$path"; ((count+=1)); }; done
  printf -v "$__count_var" '%s' "$count"
}

_sbctl_remove_all() {
  heading "删除"
  cat <<'EOF_ERASE'

⚠ 即将永久删除 sbctl 管理的全部数据：
  - sing-box 核心与 sbctl
  - 配置、用户凭据、托管证书
  - sbctl 签发的 Let's Encrypt 数据
  - 独立 Certbot 环境与自动续期任务
  - sbctl 的 BBR 配置
  - 所有 sbctl 备份

不会删除系统 Certbot、其他网站的 /etc/letsencrypt 数据或其他系统软件包。
此模式不会保留最终备份。
EOF_ERASE
  printf '输入 DELETE 确认：'
  local answer failures=0 residual=0
  read -r answer || { echo; return 0; }
  [[ $answer == DELETE ]] || { info "已取消彻底删除。"; return 0; }
  uninstall_confirmed=1
  echo
  _uninstall_snapshot_metadata
  cleanup_step "停止并删除流量统计" traffic_remove_all || ((failures+=1))
  cleanup_step "停止自动续期" _remove_renewal_jobs || ((failures+=1))
  if ((failures == 0)); then cleanup_step "删除托管证书" _remove_managed_certificates || ((failures+=1)); fi
  if ((failures == 0)); then cleanup_step "删除独立 Certbot 环境" _remove_certbot_environment || ((failures+=1)); fi
  if ((failures == 0)); then cleanup_step "卸载 sing-box 核心" _remove_sing_box_core || ((failures+=1)); fi
  if ((failures == 0)); then cleanup_step "撤销 BBR 配置" _remove_bbr_settings || ((failures+=1)); fi
  if ((failures > 0)); then
    rm -f "$SNAPSHOT_META"
    warn "清理未完成，保留配置、元数据和 sbctl 命令以便重试。"
    return 1
  fi
  if ! cleanup_step "删除配置与元数据" _remove_config_and_metadata; then
    rm -f "$SNAPSHOT_META"
    warn "配置清理未完成，保留 sbctl 命令以便重试。"
    return 1
  fi
  cleanup_step "删除 sbctl 命令与模块" _remove_quick_command_and_libs || ((failures+=1))
  cleanup_step "删除所有备份" _remove_backups || ((failures+=1))
  heading "残留检查"; _scan_sbctl_residuals residual
  rm -f "$SNAPSHOT_META"
  printf '执行结果：失败步骤 %d，检测残留 %d\n' "$failures" "$residual"
  ((failures == 0))
}

uninstall_sing_box() {
  ensure_dependencies uninstall
  local uninstall_confirmed=0
  _sbctl_remove_all || return $?
  # Clean up Hysteria2 port hopping rules if sing-box was removed
  if ((uninstall_confirmed)) && ! sing_box_installed; then
    traffic_runtime_stop || warn "流量统计运行时未能完全停止。"
    hy2_hop_clear_rules
    hy2_hop_boot_service_remove
  fi
}
