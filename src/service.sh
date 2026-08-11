# shellcheck shell=bash
# BBR safety, diagnostics and residual scanning.
# Service definition lives in engine.sh (canonical, hardened version).

bbr_manager() {
  local own=0 peer=0 unknown=0 current=""
  if [[ -f $SBCTL_BBR_CONFIG ]]; then
    if grep -q '^# managed by sbctl$' "$SBCTL_BBR_CONFIG" 2>/dev/null; then own=1; else unknown=1; fi
  fi
  [[ -f $XRAYCTL_BBR_CONFIG ]] && peer=1
  if ((peer && (own || unknown))); then printf 'both'; return; fi
  if ((own)); then printf 'sbctl'; return; fi
  if ((peer)); then printf 'xrayctl'; return; fi
  if ((unknown)); then printf 'external'; return; fi
  [[ -r /proc/sys/net/ipv4/tcp_congestion_control ]] && current=$(< /proc/sys/net/ipv4/tcp_congestion_control)
  if [[ $current == bbr ]]; then printf 'external'; else printf 'none'; fi
}

bbr_remove_known_persistence() {
  rm -f -- "$SBCTL_BBR_CONFIG" "$XRAYCTL_BBR_CONFIG"
  meta_resource_remove bbrConfig
}

enable_bbr() {
  ensure_dependencies bbr
  command_exists sysctl || die "缺少 sysctl。"
  local config=$SBCTL_BBR_CONFIG qdisc_ok=0 available
  if [[ -e $config ]] && ! grep -q '^# managed by sbctl$' "$config" 2>/dev/null; then
    warn "检测到非 sbctl 管理的 BBR 配置，拒绝覆盖：$config"
    return 1
  fi
  [[ -w /proc/sys/net/ipv4/tcp_congestion_control ]] || { warn "当前容器/内核不允许修改拥塞控制参数。"; return 0; }
  if command_exists modprobe; then run_bounded 5 modprobe tcp_bbr >/dev/null 2>&1 || true; fi
  available=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)
  grep -qw bbr <<<"$available" || { warn "当前内核未提供 BBR。"; return 0; }
  if [[ -e /proc/sys/net/core/default_qdisc ]] && run_bounded 5 sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then qdisc_ok=1; fi
  if ! run_bounded 5 sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
    warn "无法启用 BBR；可能处于受限 NAT/LXC/OpenVZ 容器。"
    return 0
  fi
  mkdir -p /etc/sysctl.d
  rm -f -- "$XRAYCTL_BBR_CONFIG"
  {
    printf '# managed by sbctl\n'
    ((qdisc_ok)) && printf 'net.core.default_qdisc=fq\n'
    printf 'net.ipv4.tcp_congestion_control=bbr\n'
  } >"$config"
  meta_resource_register bbrConfig "$config"
  info "BBR 已启用。"
}

disable_bbr() {
  ensure_dependencies bbr-disable
  command_exists sysctl || die "缺少 sysctl。"
  local available fallback="" current=""
  current=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)
  if [[ $current != bbr ]]; then
    bbr_remove_known_persistence
    info "BBR 当前未启用；已清理 xrayctl/sbctl 的已知持久化配置。"
    return 0
  fi
  [[ -w /proc/sys/net/ipv4/tcp_congestion_control ]] || { warn "当前环境不允许修改拥塞控制参数。"; return 0; }
  available=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)
  if grep -qw cubic <<<"$available"; then fallback=cubic
  elif grep -qw reno <<<"$available"; then fallback=reno
  else fallback=$(tr ' ' '\n' <<<"$available" | awk '$0!="" && $0!="bbr" {print; exit}'); fi
  [[ -n $fallback ]] || { warn "没有找到可恢复的拥塞控制算法。"; return 1; }
  run_bounded 5 sysctl -w net.ipv4.tcp_congestion_control="$fallback" >/dev/null 2>&1 \
    || { warn "恢复拥塞控制算法失败。"; return 1; }
  if [[ -e /proc/sys/net/core/default_qdisc ]]; then run_bounded 5 sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true; fi
  bbr_remove_known_persistence
  info "BBR 已关闭；当前拥塞控制算法：${fallback}。"
}
# Canonical _remove_bbr_settings lives in uninstall.sh
# Canonical _scan_sbctl_residuals lives in uninstall.sh

system_diagnostics() {
  ensure_dependencies diagnose
  local v4="" v6="" virt=unknown certs=0 auto=0 account_count=0 unit="" hardening=不适用
  command_exists systemd-detect-virt && virt=$(systemd-detect-virt 2>/dev/null || printf none)
  v4=$(detect_public_ipv4 || true)
  v6=$(detect_public_ipv6 || true)
  init_meta
  certs=$(managed_certificate_count 2>/dev/null || printf 0)
  auto=$(meta_cert_auto_renew_certs 2>/dev/null | awk 'NF{n++} END{print n+0}')
  account_count=$(certbot_account_ids 2>/dev/null | awk 'NF{n++} END{print n+0}')
  case $(init_system) in
    systemd)
      unit="${SYSTEMD_UNIT_DIR}/${SERVICE_NAME}.service"
      if [[ -r $unit ]] && grep -q '^NoNewPrivileges=true$' "$unit" && grep -q '^ProtectSystem=strict$' "$unit"; then hardening=已启用; else hardening=缺失; fi
      ;;
    openrc)
      unit="${OPENRC_INIT_DIR}/${SERVICE_NAME}"
      if [[ -r $unit ]] && grep -q '^supervisor="supervise-daemon"$' "$unit"; then hardening=supervise-daemon; else hardening=缺失; fi
      ;;
  esac
  heading "系统诊断"
  printf '系统: %s %s\n' "$(uname -s)" "$(uname -r)"
  printf '虚拟化: %s\n' "$virt"
  printf '初始化: %s\n' "$(init_system)"
  printf 'sing-box: %s\n' "$(sing_box_version_summary)"
  printf '服务: %s  |  开机自启: %s\n' "$(service_state_summary)" "$(startup_state_summary)"
  printf '服务硬化: %s\n' "$hardening"
  printf '公网 IPv4: %s\n' "${v4:-未检测到}"
  printf '公网 IPv6: %s\n' "${v6:-未检测到}"
  printf 'BBR: %s\n' "$(bbr_state_summary)"
  printf 'BBR 持久化来源: %s\n' "$(bbr_manager)"
  printf '配置: %s\n' "$CONFIG_FILE"
  printf 'metadata schema: %s\n' "$(jq -r '.schema // "?"' "$META_FILE" 2>/dev/null || printf '?')"
  printf '托管证书: %s  |  自动续期: %s  |  Certbot 账户: %s\n' "$certs" "$auto" "$account_count"
  if load_cloudflare_credentials 2>/dev/null; then printf 'Cloudflare DNS: 已配置\n'; else printf 'Cloudflare DNS: 未配置\n'; fi
  if [[ -f $CONFIG_FILE ]]; then
    printf '入站: %s  |  出站: %s\n' "$(jq '.inbounds|length' "$CONFIG_FILE" 2>/dev/null || printf '?')" "$(jq '.outbounds|length' "$CONFIG_FILE" 2>/dev/null || printf '?')"
    if validate_candidate "$CONFIG_FILE"; then printf '配置检查: 通过\n'; else printf '配置检查: 失败\n'; fi
  fi
}

bbr_state_summary() {
  if [[ -r /proc/sys/net/ipv4/tcp_congestion_control ]]; then
    [[ $(< /proc/sys/net/ipv4/tcp_congestion_control) == bbr ]] && printf '已启用' || printf '未启用'
  else
    printf '不可用'
  fi
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


# ---- sing-box lifecycle ----
version_ge() {
  local have=$1 need=$2 h1 h2 h3 n1 n2 n3
  IFS=. read -r h1 h2 h3 <<<"$have"
  IFS=. read -r n1 n2 n3 <<<"$need"
  h1=${h1:-0}; h2=${h2:-0}; h3=${h3:-0}
  n1=${n1:-0}; n2=${n2:-0}; n3=${n3:-0}
  ((10#$h1 > 10#$n1)) && return 0
  ((10#$h1 < 10#$n1)) && return 1
  ((10#$h2 > 10#$n2)) && return 0
  ((10#$h2 < 10#$n2)) && return 1
  ((10#$h3 >= 10#$n3))
}

require_sing_box() { refresh_binary_path; sing_box_installed || die "sing-box 尚未安装，请先运行 sbctl install。"; }

require_supported_core() {
  local version
  require_sing_box
  version=$(sing_box_version)
  [[ -n $version ]] || die "无法识别 sing-box 版本。"
  version_ge "$version" 1.12.0 || die "sbctl 需要 sing-box >= 1.12.0（AnyTLS 从 1.12.0 起支持），当前为 ${version}。"
}

restart_service_checked() {
  service_exists || return 0
  service_restart || return 1
  sleep 0.2
  service_is_active
}

# Hardened service definition.
create_service_definition() {
  refresh_binary_path
  mkdir -p "$DATA_DIR" "$CONFIG_DIR"
  case $(init_system) in
    systemd)
      mkdir -p "$SYSTEMD_UNIT_DIR"
      cat >"${SYSTEMD_UNIT_DIR}/${SERVICE_NAME}.service" <<EOF_UNIT
[Unit]
Description=sing-box service managed by sbctl
Documentation=https://sing-box.sagernet.org/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=${SING_BOX_BIN} run -D ${DATA_DIR} -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectHostname=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
ReadWritePaths=${DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF_UNIT
      systemctl daemon-reload
      meta_resource_register serviceDefinition "${SYSTEMD_UNIT_DIR}/${SERVICE_NAME}.service"
      ;;
    openrc)
      mkdir -p "$OPENRC_INIT_DIR"
      cat >"${OPENRC_INIT_DIR}/$SERVICE_NAME" <<EOF_RC
#!/sbin/openrc-run
name="sing-box"
description="sing-box service managed by sbctl"
command="${SING_BOX_BIN}"
command_args="run -D ${DATA_DIR} -c ${CONFIG_FILE}"
command_user="root:root"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
umask 077
$(printf '%s' 'depend() { need net; }')
EOF_RC
      chmod 755 "${OPENRC_INIT_DIR}/$SERVICE_NAME"
      meta_resource_register serviceDefinition "${OPENRC_INIT_DIR}/${SERVICE_NAME}"
      ;;
    *) die "未检测到 systemd 或 OpenRC。";;
  esac
  meta_resource_register dataDir "$DATA_DIR"
}

install_quick_command() {
  local source=${SBCTL_ENTRYPOINT:-${BASH_SOURCE[0]:-}} downloaded=""
  mkdir -p "$(dirname "$QUICK_COMMAND")" "$(dirname "$QUICK_SYMLINK")"
  if [[ -z $source || ! -r $source ]] || ! grep -q '^# sbctl - sing-box Linux terminal manager' "$source" 2>/dev/null; then
    downloaded=$(temp_file)
    curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 60 "$SCRIPT_DOWNLOAD_URL" -o "$downloaded" || die "sbctl 下载失败。"
    grep -q '^# sbctl - sing-box Linux terminal manager' "$downloaded" || die "下载内容校验失败。"
    source=$downloaded
  fi
  if [[ $(readlink -f "$source" 2>/dev/null || printf '%s' "$source") == $(readlink -f "$QUICK_COMMAND" 2>/dev/null || printf '%s' "$QUICK_COMMAND") ]]; then
    chmod 755 "$QUICK_COMMAND"
  else
    install -m 755 "$source" "$QUICK_COMMAND"
  fi
  ln -sfn "$QUICK_COMMAND" "$QUICK_SYMLINK"
  [[ -z $downloaded ]] || rm -f "$downloaded"
  meta_resource_register quickCommand "$QUICK_COMMAND"
  meta_resource_register quickSymlink "$QUICK_SYMLINK"
  [[ $LIB_DIR != /usr/local/lib/sbctl ]] || meta_resource_register libDir "$LIB_DIR"
}

install_or_update_sing_box() {
  ensure_dependencies install
  local version=${1-} installer manager had_config=0
  [[ -f $CONFIG_FILE ]] && had_config=1
  manager=$(pkg_manager)
  if [[ $manager == apk ]]; then
    run_bounded 180 apk add --no-cache --upgrade sing-box || die "sing-box 安装/更新失败或超时。"
  else
    installer=$(temp_file)
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 60 \
      "$OFFICIAL_INSTALLER_URL" -o "$installer" || { rm -f "$installer"; die "sing-box 官方安装器下载失败或超时。"; }
    chmod 700 "$installer"
    if [[ -n $version ]]; then
      TERM=${TERM:-xterm} run_bounded 180 bash "$installer" --version "${version#v}" || { rm -f "$installer"; die "sing-box 安装失败或超时。"; }
    else
      TERM=${TERM:-xterm} run_bounded 180 bash "$installer" || { rm -f "$installer"; die "sing-box 安装失败或超时。"; }
    fi
    rm -f "$installer"
  fi
  # Invalidate caches after install/update
  sbc_invalidate_install_cache
  refresh_binary_path
  sing_box_installed || die "sing-box 安装失败。"
  require_supported_core
  if ((had_config)); then
    ensure_config
  else
    write_default_config
  fi
  create_service_definition
  install_quick_command
  validate_candidate "$CONFIG_FILE"
  service_enable
  if ! service_is_active; then service_start; else service_restart; fi
  info "sing-box 已就绪：$($SING_BOX_BIN version | sed -n '1p')"
}

# ---- status / ops ----
show_status() {
  heading "sing-box 状态"
  if sing_box_installed; then "$SING_BOX_BIN" version | sed -n '1,2p'; else printf 'sing-box: 未安装\n'; fi
  printf '初始化系统: %s\n' "$(init_system)"
  if service_exists; then
    printf '服务: %s\n' "$(service_state_summary)"
    printf '开机自启: %s\n' "$(startup_state_summary)"
  else printf '服务: 未安装\n'; fi
  [[ -f $CONFIG_FILE ]] && printf '入站数: %s\n配置: %s\n' "$(jq '.inbounds|length' "$CONFIG_FILE" 2>/dev/null || printf '?')" "$CONFIG_FILE"
}

service_action() {
  ensure_dependencies service
  local action=$1
  service_exists || die "sing-box 服务不存在。"
  case $action in
    start) service_start;; stop) service_stop;; restart) service_restart;;
    enable) service_enable; service_start;; disable) service_disable; service_stop;;
    *) die "未知服务操作：$action";;
  esac
  info "服务操作完成：${action}"
}
