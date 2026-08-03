# System-tool behavior overrides.
# UFW is intentionally operated in "default allow incoming" mode: ports remain
# reachable unless the user explicitly closes them through sbctl.

install_firewall() {
  ensure_dependencies firewall
  local manager
  if command_exists ufw; then
    ufw default allow incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw --force enable
    info "UFW 已启用。"
    return
  fi
  if command_exists firewall-cmd; then
    command_exists systemctl || die "firewalld 需要 systemd。"
    systemctl enable --now firewalld
    info "firewalld 已启用。"
    return
  fi
  manager=$(pkg_manager)
  case $manager in
    dnf|yum)
      install_packages firewalld
      systemctl enable --now firewalld
      info "firewalld 已安装并启用。"
      ;;
    *)
      install_packages ufw
      ufw default allow incoming >/dev/null
      ufw default allow outgoing >/dev/null
      ufw --force enable
      info "UFW 已安装并启用。"
      ;;
  esac
}

uninstall_firewall() {
  ensure_dependencies firewall-uninstall
  local manager
  manager=$(pkg_manager)
  if command_exists ufw; then
    confirm "卸载 UFW？卸载前会先关闭 UFW，现有 UFW 规则将不再生效。" N || return 0
    ufw --force disable >/dev/null 2>&1 || true
    case $manager in
      apt) DEBIAN_FRONTEND=noninteractive apt-get purge -y ufw ;;
      apk) apk del ufw ;;
      dnf) dnf remove -y ufw ;;
      yum) yum remove -y ufw ;;
      pacman) pacman -Rns --noconfirm ufw ;;
      zypper) zypper --non-interactive remove ufw ;;
    esac
    info "UFW 已卸载。"
    return
  fi
  if command_exists firewall-cmd; then
    confirm "卸载 firewalld？" N || return 0
    systemctl disable --now firewalld >/dev/null 2>&1 || true
    case $manager in
      apt) DEBIAN_FRONTEND=noninteractive apt-get purge -y firewalld ;;
      apk) apk del firewalld ;;
      dnf) dnf remove -y firewalld ;;
      yum) yum remove -y firewalld ;;
      pacman) pacman -Rns --noconfirm firewalld ;;
      zypper) zypper --non-interactive remove firewalld ;;
    esac
    info "firewalld 已卸载。"
    return
  fi
  info "未安装 UFW/firewalld。"
}

show_firewall_rules() {
  require_root firewall-rules
  heading "当前防火墙规则"
  if command_exists ufw; then
    LC_ALL=C ufw status numbered
  elif command_exists firewall-cmd; then
    firewall-cmd --list-all
  else
    info "未安装 UFW/firewalld。"
  fi
}

_ufw_rule_numbers_for_port() {
  local port=$1 proto=$2
  LC_ALL=C ufw status numbered 2>/dev/null \
    | sed -nE "/${port}\\/${proto}([[:space:]]|$)/s/^\\[[[:space:]]*([0-9]+)\\].*/\\1/p" \
    | sort -rn
}

_ufw_delete_rules_for_port() {
  local port=$1 proto=$2 rule_no
  while IFS= read -r rule_no; do
    [[ -n $rule_no ]] || continue
    ufw --force delete "$rule_no" >/dev/null
  done < <(_ufw_rule_numbers_for_port "$port" "$proto")
}

_ufw_rule_matches() {
  local port=$1 proto=$2 expected=$3
  LC_ALL=C ufw status numbered 2>/dev/null \
    | grep -Eq "^\\[[[:space:]]*[0-9]+\\][[:space:]]+${port}/${proto}([[:space:]]|$).*${expected}[[:space:]]+IN([[:space:]]|$)"
}

firewall_port_action() {
  ensure_dependencies firewall
  local action=$1 port=$2 protocol=${3:-tcp} p expected
  local protocols=()
  validate_port "$port" || die "端口必须为 1-65535。"
  [[ $protocol == tcp || $protocol == udp || $protocol == both ]] || die "协议必须是 tcp、udp 或 both。"
  if [[ $protocol == both ]]; then protocols=(tcp udp); else protocols=("$protocol"); fi

  if command_exists ufw; then
    for p in "${protocols[@]}"; do
      _ufw_delete_rules_for_port "$port" "$p"
      if [[ $action == open ]]; then
        ufw prepend allow in proto "$p" to any port "$port"
        expected=ALLOW
      else
        ufw prepend deny in proto "$p" to any port "$port"
        expected=DENY
      fi
      ufw reload >/dev/null
      _ufw_rule_matches "$port" "$p" "$expected" || die "UFW 规则写入失败：${port}/${p} 未出现 ${expected} IN。"
    done
  elif command_exists firewall-cmd; then
    for p in "${protocols[@]}"; do
      if [[ $action == open ]]; then
        firewall-cmd --permanent --add-port="${port}/${p}"
      else
        firewall-cmd --permanent --remove-port="${port}/${p}" || true
      fi
    done
    firewall-cmd --reload
  else
    die "未检测到 UFW/firewalld，请先安装防火墙。"
  fi
  info "防火墙端口操作完成：${action} ${port}/${protocol}"
}

disable_bbr() {
  ensure_dependencies bbr-disable
  command_exists sysctl || die "缺少 sysctl。"
  local available fallback=""
  available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
  if grep -qw cubic <<<"$available"; then
    fallback=cubic
  elif grep -qw reno <<<"$available"; then
    fallback=reno
  else
    fallback=$(tr ' ' '\n' <<<"$available" | awk '$0!="" && $0!="bbr" {print; exit}')
  fi
  [[ -n $fallback ]] || die "没有找到可用于替代 BBR 的拥塞控制算法。"
  cat >/etc/sysctl.d/99-sbctl-bbr.conf <<EOF_BBR_OFF
net.ipv4.tcp_congestion_control=${fallback}
EOF_BBR_OFF
  sysctl -p /etc/sysctl.d/99-sbctl-bbr.conf >/dev/null
  [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) != bbr ]] || die "BBR 关闭失败。"
  info "BBR 已关闭；当前拥塞控制算法：${fallback}。"
}

toggle_bbr() {
  if [[ -r /proc/sys/net/ipv4/tcp_congestion_control ]] && [[ $(< /proc/sys/net/ipv4/tcp_congestion_control) == bbr ]]; then
    disable_bbr
  else
    enable_bbr
  fi
}

firewall_menu() {
  local choice
  while true; do
    clear_screen; heading "防火墙"
    printf '状态: %s\n\n' "$(firewall_state_summary)"
    printf '1) 安装/启用\n2) 查看当前规则\n3) 放行端口\n4) 关闭端口\n5) 卸载 UFW/firewalld\n0) 返回\n'
    read -r -p "请选择: " choice
    case $choice in
      1) run_menu_action install_firewall; pause;;
      2) run_menu_action show_firewall_rules; pause;;
      3) run_menu_action manage_firewall_port open; pause;;
      4) run_menu_action manage_firewall_port close; pause;;
      5) run_menu_action uninstall_firewall; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}

system_menu() {
  local choice
  while true; do
    clear_screen; heading "系统工具"
    printf 'BBR: %s  |  防火墙: %s\n\n' "$(bbr_state_summary)" "$(firewall_state_summary)"
    printf '1) 防火墙管理\n2) BBR 开启/关闭\n3) 系统诊断\n4) 修复快捷命令\n0) 返回\n'
    read -r -p "请选择: " choice
    case $choice in
      1) firewall_menu;;
      2) run_menu_action toggle_bbr; pause;;
      3) run_menu_action system_diagnostics; pause;;
      4) run_menu_action repair_quick_command; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}
