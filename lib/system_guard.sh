# shellcheck shell=bash
# Service sandboxing, BBR safety, diagnostics and residual scanning.

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
depend() { need net; }
EOF_RC
      chmod 755 "${OPENRC_INIT_DIR}/$SERVICE_NAME"
      meta_resource_register serviceDefinition "${OPENRC_INIT_DIR}/${SERVICE_NAME}"
      ;;
    *) die "未检测到 systemd 或 OpenRC。";;
  esac
  meta_resource_register dataDir "$DATA_DIR"
}

enable_bbr() {
  ensure_dependencies bbr
  command_exists sysctl || die "缺少 sysctl。"
  local config=/etc/sysctl.d/99-sbctl-bbr.conf qdisc_ok=0 available
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
  local config=/etc/sysctl.d/99-sbctl-bbr.conf available fallback="" current=""
  current=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)
  if [[ $current != bbr ]]; then
    if [[ -f $config ]] && grep -q '^# managed by sbctl$' "$config" 2>/dev/null; then rm -f "$config"; fi
    meta_resource_remove bbrConfig
    info "BBR 当前未启用。"
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
  if [[ -f $config ]] && grep -q '^# managed by sbctl$' "$config" 2>/dev/null; then rm -f "$config"; fi
  meta_resource_remove bbrConfig
  info "BBR 已关闭；当前拥塞控制算法：${fallback}。"
}

_remove_bbr_settings() {
  local config=/etc/sysctl.d/99-sbctl-bbr.conf available fallback="" current=""
  [[ -f $config ]] || return 0
  grep -q '^# managed by sbctl$' "$config" 2>/dev/null || { warn "BBR 配置不属于 sbctl，跳过：$config"; return 0; }
  current=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)
  if [[ $current == bbr && -w /proc/sys/net/ipv4/tcp_congestion_control ]]; then
    available=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)
    if grep -qw cubic <<<"$available"; then fallback=cubic; elif grep -qw reno <<<"$available"; then fallback=reno; fi
    if [[ -n $fallback ]]; then run_bounded 5 sysctl -w net.ipv4/tcp_congestion_control="$fallback" >/dev/null 2>&1 || true; fi
  fi
  rm -f "$config"
}

_scan_sbctl_residuals() {
  local __count_var=$1 include_backups=${2:-0} count=0 path data_path service_path cf_path
  local paths=("$QUICK_COMMAND" "$QUICK_SYMLINK" "$CONFIG_FILE" "$META_FILE" "$CERT_DIR" "$CERTBOT_VENV" "$CERTBOT_CONFIG_DIR" "$CERTBOT_WORK_DIR" "$CERTBOT_LOGS_DIR" \
    "${SYSTEMD_UNIT_DIR}/sbctl-certbot-renew.service" "${SYSTEMD_UNIT_DIR}/sbctl-certbot-renew.timer" /etc/periodic/daily/sbctl-certbot-renew /var/log/sing-box.log)
  case $(init_system) in
    systemd) service_path="${SYSTEMD_UNIT_DIR}/${SERVICE_NAME}.service";;
    openrc) service_path="${OPENRC_INIT_DIR}/${SERVICE_NAME}";;
  esac
  [[ -z ${service_path:-} ]] || paths+=("$service_path")
  [[ $LIB_DIR != /usr/local/lib/sbctl ]] || paths+=("$LIB_DIR")
  data_path=$(_snapshot_meta_resource_get dataDir 2>/dev/null || true)
  [[ -z $data_path ]] || paths+=("$data_path")
  cf_path=$(_snapshot_meta_resource_get cloudflareCredentials 2>/dev/null || true)
  [[ -z $cf_path ]] || paths+=("$cf_path")
  ((include_backups == 0)) || paths+=("$BACKUP_DIR" /etc/sysctl.d/99-sbctl-bbr.conf)
  for path in "${paths[@]}"; do
    [[ ! -e $path && ! -L $path ]] || { printf '  ✗ 残留: %s\n' "$path"; ((count+=1)); }
  done
  for path in "$CERTBOT_HOOK_DIR"/sbctl-*; do
    [[ ! -e $path ]] || { printf '  ✗ 残留: %s\n' "$path"; ((count+=1)); }
  done
  if pgrep -x sing-box >/dev/null 2>&1; then printf '  ✗ 残留: sing-box 进程仍在运行\n'; ((count+=1)); fi
  printf -v "$__count_var" '%s' "$count"
}

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
  printf '配置: %s\n' "$CONFIG_FILE"
  printf 'metadata schema: %s\n' "$(jq -r '.schema // "?"' "$META_FILE" 2>/dev/null || printf '?')"
  printf '托管证书: %s  |  自动续期: %s  |  Certbot 账户: %s\n' "$certs" "$auto" "$account_count"
  if load_cloudflare_credentials 2>/dev/null; then printf 'Cloudflare DNS: 已配置\n'; else printf 'Cloudflare DNS: 未配置\n'; fi
  if [[ -f $CONFIG_FILE ]]; then
    printf '入站: %s  |  出站: %s\n' "$(jq '.inbounds|length' "$CONFIG_FILE" 2>/dev/null || printf '?')" "$(jq '.outbounds|length' "$CONFIG_FILE" 2>/dev/null || printf '?')"
    if validate_candidate "$CONFIG_FILE"; then printf '配置检查: 通过\n'; else printf '配置检查: 失败\n'; fi
  fi
}
