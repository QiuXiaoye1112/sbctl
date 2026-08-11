# shellcheck shell=bash
# BBR safety, diagnostics and residual scanning.
# Service definition lives in engine.sh (canonical, hardened version).

enable_bbr() {
  ensure_dependencies bbr
  command_exists sysctl || die "缺少 sysctl。"
  local config=/etc/sysctl.d/99-sbctl-bbr.conf qdisc_ok=0 available
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
  printf '配置: %s\n' "$CONFIG_FILE"
  printf 'metadata schema: %s\n' "$(jq -r '.schema // "?"' "$META_FILE" 2>/dev/null || printf '?')"
  printf '托管证书: %s  |  自动续期: %s  |  Certbot 账户: %s\n' "$certs" "$auto" "$account_count"
  if load_cloudflare_credentials 2>/dev/null; then printf 'Cloudflare DNS: 已配置\n'; else printf 'Cloudflare DNS: 未配置\n'; fi
  if [[ -f $CONFIG_FILE ]]; then
    printf '入站: %s  |  出站: %s\n' "$(jq '.inbounds|length' "$CONFIG_FILE" 2>/dev/null || printf '?')" "$(jq '.outbounds|length' "$CONFIG_FILE" 2>/dev/null || printf '?')"
    if validate_candidate "$CONFIG_FILE"; then printf '配置检查: 通过\n'; else printf '配置检查: 失败\n'; fi
  fi
}
