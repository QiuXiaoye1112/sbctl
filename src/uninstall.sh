# Three-level uninstall model aligned with xrayctl, adapted to sing-box/systemd/OpenRC.

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
  case $path in
    /opt/sbctl/certbot|/var/lib/sbctl/letsencrypt|/var/lib/sbctl/certbot-work|/var/log/sbctl/certbot|/var/backups/sbctl|/usr/local/lib/sbctl|/etc/sing-box/certs) :;;
    *) [[ -n $recorded && $recorded == "$path" ]] || { warn "未确认目录归 sbctl 所有，跳过：$path"; return 1; };;
  esac
  [[ ! -e $path ]] || rm -rf -- "$path"
}

_remove_renewal_jobs() {
  case $(init_system) in
    systemd)
      systemctl disable --now sbctl-certbot-renew.timer >/dev/null 2>&1 || true
      systemctl stop sbctl-certbot-renew.service >/dev/null 2>&1 || true
      rm -f "${SYSTEMD_UNIT_DIR}/sbctl-certbot-renew.service" "${SYSTEMD_UNIT_DIR}/sbctl-certbot-renew.timer"
      systemctl daemon-reload >/dev/null 2>&1 || true
      ;;
    openrc) rm -f /etc/periodic/daily/sbctl-certbot-renew;;
  esac
}

_remove_legacy_certbot_assets() {
  local hook name
  for hook in "$CERTBOT_HOOK_DIR"/sbctl-*; do
    [[ -e $hook ]] || continue
    name=$(basename "$hook"); name=${name#sbctl-}
    if [[ -n $name && -f /etc/letsencrypt/renewal/${name}.conf ]] && command_exists certbot; then
      certbot delete --cert-name "$name" --non-interactive >/dev/null 2>&1 || warn "旧版 Certbot lineage 删除失败：$name"
    fi
    rm -f "$hook"
  done
}

_remove_managed_certificates() {
  local id source cert_name
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    source=$(_snapshot_meta_cert_get_field "$id" source); cert_name=$(_snapshot_meta_cert_get_field "$id" certName)
    if [[ $source == letsencrypt && -n $cert_name && -x $CERTBOT_BIN && -f $CERTBOT_CONFIG_DIR/renewal/${cert_name}.conf ]]; then
      certbot_cmd delete --cert-name "$cert_name" --non-interactive >/dev/null 2>&1 || warn "Certbot lineage 删除失败：$cert_name"
    fi
    rm -f "$CERT_DIR/${id}.crt" "$CERT_DIR/${id}.key"
  done < <(_snapshot_meta_cert_list)
  _remove_legacy_certbot_assets
}

_remove_certbot_environment() {
  _safe_remove_sbctl_dir "$CERTBOT_CONFIG_DIR" certbotConfigDir || true
  _safe_remove_sbctl_dir "$CERTBOT_WORK_DIR" certbotWorkDir || true
  _safe_remove_sbctl_dir "$CERTBOT_LOGS_DIR" certbotLogsDir || true
  _safe_remove_sbctl_dir "$CERTBOT_VENV" certbotVenv || true
  rmdir /var/log/sbctl /opt/sbctl 2>/dev/null || true
}

_remove_sbctl_service_definition() {
  case $(init_system) in
    systemd)
      local unit="${SYSTEMD_UNIT_DIR}/${SERVICE_NAME}.service"
      if [[ -f $unit ]] && grep -q 'managed by sbctl' "$unit" 2>/dev/null; then rm -f "$unit"; fi
      systemctl daemon-reload >/dev/null 2>&1 || true
      ;;
    openrc)
      local init="${OPENRC_INIT_DIR}/${SERVICE_NAME}"
      if [[ -f $init ]] && grep -q 'managed by sbctl' "$init" 2>/dev/null; then rm -f "$init"; fi
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
      service_stop >/dev/null 2>&1 || true
      service_disable >/dev/null 2>&1 || true
      _remove_sbctl_service_definition
    fi
    return 0
  fi
  service_stop >/dev/null 2>&1 || true
  service_disable >/dev/null 2>&1 || true
  _remove_managed_sing_box_release_binary || rc=1
  ((rc != 0)) || _clear_sing_box_install_metadata
  _remove_sbctl_service_definition
  return "$rc"
}

_remove_quick_command_and_libs() {
  if [[ -L $QUICK_SYMLINK ]] && [[ $(readlink "$QUICK_SYMLINK" 2>/dev/null) == "$QUICK_COMMAND" ]]; then rm -f "$QUICK_SYMLINK"; fi
  if [[ -f $QUICK_COMMAND ]] && grep -q '^# sbctl - sing-box Linux terminal manager' "$QUICK_COMMAND" 2>/dev/null; then rm -f "$QUICK_COMMAND"; fi
  if [[ $LIB_DIR == /usr/local/lib/sbctl ]]; then _safe_remove_sbctl_dir "$LIB_DIR" libDir || true; fi
  hash -r 2>/dev/null || true
}

_remove_config_and_metadata() {
  rm -f "$CONFIG_FILE"
  _safe_remove_sbctl_dir "$CERT_DIR" certDir || true
  [[ ! -d $CONFIG_DIR ]] || rmdir "$CONFIG_DIR" 2>/dev/null || true
  rm -f "$META_FILE"
  rmdir "$(dirname "$META_FILE")" 2>/dev/null || true
  if [[ -d $DATA_DIR ]]; then
    local recorded_data
    recorded_data=$(_snapshot_meta_resource_get dataDir)
    if [[ -n $recorded_data && $recorded_data == "$DATA_DIR" ]]; then _safe_remove_sbctl_dir "$DATA_DIR" dataDir || true; else rmdir "$DATA_DIR" 2>/dev/null || true; fi
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
  _safe_remove_sbctl_dir "$BACKUP_DIR" backupDir
}

_scan_sbctl_residuals() {
  local __count_var=$1 include_backups=${2:-0} count=0 path
  local paths=("$QUICK_COMMAND" "$QUICK_SYMLINK" "$CONFIG_FILE" "$META_FILE" "$CERT_DIR" "$CERTBOT_VENV" "$CERTBOT_CONFIG_DIR" "$CERTBOT_WORK_DIR" "$CERTBOT_LOGS_DIR" \
    "$TRAFFIC_FILE" "$TRAFFIC_SYSTEMD_SERVICE" "$TRAFFIC_SYSTEMD_TIMER" "$TRAFFIC_OPENRC_SERVICE" \
    "${SYSTEMD_UNIT_DIR}/sbctl-certbot-renew.service" "${SYSTEMD_UNIT_DIR}/sbctl-certbot-renew.timer" /etc/periodic/daily/sbctl-certbot-renew)
  [[ $LIB_DIR != /usr/local/lib/sbctl ]] || paths+=("$LIB_DIR")
  ((include_backups == 0)) || paths+=("$BACKUP_DIR" /etc/sysctl.d/99-sbctl-bbr.conf)
  for path in "${paths[@]}"; do
    [[ ! -e $path && ! -L $path ]] || { printf '  ✗ 残留: %s\n' "$path"; ((count+=1)); }
  done
  for path in "$CERTBOT_HOOK_DIR"/sbctl-*; do [[ ! -e $path ]] || { printf '  ✗ 残留: %s\n' "$path"; ((count+=1)); }; done
  printf -v "$__count_var" '%s' "$count"
}

_sbctl_uninstall_level_0() {
  heading "卸载程序"
  confirm "卸载 sing-box 核心，但保留配置、证书、备份、sbctl 和自动续期？" N || return 0
  if [[ -f $CONFIG_FILE ]]; then
    local backup="$BACKUP_DIR/pre-uninstall-$(timestamp).tar.gz"
    backup_all "$backup" >/dev/null 2>&1 && info "卸载前备份：$backup" || warn "卸载前备份失败，仍继续仅卸载核心。"
  fi
  if ! _remove_sing_box_core; then
    warn "sing-box 核心未完全卸载；未确认归 sbctl 管理的 binary 已保留。"
    return 1
  fi
  info "sing-box 核心已卸载；配置、证书、sbctl、续期任务和备份已保留。"
  info "需要时运行 sbctl install 可重新安装。"
}

_sbctl_uninstall_level_1() {
  heading "完全卸载"
  confirm "将卸载 sing-box/sbctl，并删除配置、托管证书和 Certbot 数据；备份保留。确定吗？" N || return 0
  local backup residual=0 failures=0
  if [[ -f $CONFIG_FILE ]]; then
    backup="$BACKUP_DIR/pre-uninstall-$(timestamp).tar.gz"
    backup_all "$backup" >/dev/null 2>&1 || { warn "最终备份失败，已取消完全卸载。"; return 1; }
    info "最终备份已创建：$backup"
  fi
  _uninstall_snapshot_metadata
  cleanup_step "停止并删除流量统计" traffic_remove_all || ((failures+=1))
  cleanup_step "停止自动续期" _remove_renewal_jobs || ((failures+=1))
  cleanup_step "删除托管证书" _remove_managed_certificates || ((failures+=1))
  cleanup_step "删除独立 Certbot 环境" _remove_certbot_environment || ((failures+=1))
  cleanup_step "卸载 sing-box 核心" _remove_sing_box_core || ((failures+=1))
  cleanup_step "删除配置与元数据" _remove_config_and_metadata || ((failures+=1))
  cleanup_step "删除 sbctl 命令与模块" _remove_quick_command_and_libs || ((failures+=1))
  heading "残留检查"; _scan_sbctl_residuals residual 0
  rm -f "$SNAPSHOT_META"
  ((failures == 0)) || warn "有 ${failures} 个清理步骤未完全成功。"
  ((residual == 0)) || warn "检测到 ${residual} 项残留。"
  info "完全卸载完成；备份保留在 ${BACKUP_DIR}。"
}

_sbctl_uninstall_level_2() {
  heading "彻底删除"
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
  _uninstall_snapshot_metadata
  cleanup_step "停止并删除流量统计" traffic_remove_all || ((failures+=1))
  cleanup_step "停止自动续期" _remove_renewal_jobs || ((failures+=1))
  cleanup_step "删除托管证书" _remove_managed_certificates || ((failures+=1))
  cleanup_step "删除独立 Certbot 环境" _remove_certbot_environment || ((failures+=1))
  cleanup_step "卸载 sing-box 核心" _remove_sing_box_core || ((failures+=1))
  cleanup_step "撤销 BBR 配置" _remove_bbr_settings || ((failures+=1))
  cleanup_step "删除配置与元数据" _remove_config_and_metadata || ((failures+=1))
  cleanup_step "删除 sbctl 命令与模块" _remove_quick_command_and_libs || ((failures+=1))
  cleanup_step "删除所有备份" _remove_backups || ((failures+=1))
  heading "残留检查"; _scan_sbctl_residuals residual 1
  rm -f "$SNAPSHOT_META"
  printf '执行结果：失败步骤 %d，检测残留 %d\n' "$failures" "$residual"
}

uninstall_sing_box() {
  ensure_dependencies uninstall
  local level=${1:-0}
  case $level in
    0) _sbctl_uninstall_level_0;;
    1) _sbctl_uninstall_level_1;;
    2) _sbctl_uninstall_level_2;;
    *) die "无效卸载级别：$level";;
  esac
  # Clean up Hysteria2 port hopping rules if sing-box was removed
  if ! sing_box_installed; then
    traffic_runtime_stop || warn "流量统计运行时未能完全停止。"
    hy2_hop_clear_rules
    hy2_hop_boot_service_remove
  fi
}
