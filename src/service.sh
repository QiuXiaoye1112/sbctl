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

_sing_box_binary_version() {
  local binary=$1
  [[ -x $binary ]] || return 1
  "$binary" version 2>/dev/null | sed -n 's/^sing-box version \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1
}

_sing_box_binary_sha256() {
  local binary=$1
  [[ -f $binary ]] || return 1
  openssl dgst -sha256 "$binary" 2>/dev/null | awk '{print $NF}'
}

_record_sing_box_install() {
  local version=$1 arch=$2 binary_sha256=$3 platform=${4-} tmp
  init_meta
  tmp=$(temp_file)
  jq --arg version "$version" --arg arch "$arch" --arg binary "$SING_BOX_RELEASE_INSTALL_PATH" \
    --arg sha256 "$binary_sha256" --arg platform "$platform" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
    .singBox={
      managed:true,
      source:"official-release",
      version:$version,
      arch:$arch,
      binary:$binary,
      sha256:$sha256,
      platform:$platform,
      updatedAt:$now
    } |
    del(.managedResources.singBoxInstallSource,
        .managedResources.singBoxBinaryPath,
        .managedResources.singBoxBinarySHA256)
  ' "$META_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
  install -m 600 "$tmp" "$META_FILE"
  rm -f "$tmp"
}

_sing_box_meta_get() {
  local field=$1
  [[ -f $META_FILE ]] || return 0
  jq -r --arg field "$field" '.singBox[$field] // empty' "$META_FILE" 2>/dev/null
}

detect_sing_box_arch() {
  local machine=${1:-$(uname -m)}
  case $machine in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    armv7l) printf 'armv7' ;;
    armv6l) printf 'armv6' ;;
    i386|i486|i586|i686) printf '386' ;;
    s390x) printf 's390x' ;;
    riscv64) printf 'riscv64' ;;
    *) error "不支持的 sing-box Release 架构：${machine}"; return 1 ;;
  esac
}

_migrate_legacy_release_metadata() {
  [[ -f $META_FILE ]] || return 1
  [[ $(_sing_box_meta_get managed) == true ]] && return 0
  local source path expected_sha256 actual_sha256 version arch
  source=$(jq -r '.managedResources.singBoxInstallSource // empty' "$META_FILE" 2>/dev/null)
  path=$(jq -r '.managedResources.singBoxBinaryPath // empty' "$META_FILE" 2>/dev/null)
  expected_sha256=$(jq -r '.managedResources.singBoxBinarySHA256 // empty' "$META_FILE" 2>/dev/null)
  [[ $source == release && $path == "$SING_BOX_RELEASE_INSTALL_PATH" && -f $path && ! -L $path && -n $expected_sha256 ]] || return 1
  actual_sha256=$(_sing_box_binary_sha256 "$path") || return 1
  [[ $actual_sha256 == "$expected_sha256" ]] || return 1
  version=$(_sing_box_binary_version "$path") || return 1
  arch=$(detect_sing_box_arch) || return 1
  _record_sing_box_install "$version" "$arch" "$actual_sha256" legacy-release
}

_sing_box_target_is_managed() {
  [[ $(_sing_box_meta_get managed) == true ]] || _migrate_legacy_release_metadata || return 1
  [[ $(_sing_box_meta_get source) == official-release ]] || return 1
  [[ $(_sing_box_meta_get binary) == "$SING_BOX_RELEASE_INSTALL_PATH" ]] || return 1
}

require_sing_box() { refresh_binary_path; sing_box_installed || die "sing-box 尚未安装，请先自行安装 sing-box。"; }

require_supported_core() {
  local version
  require_sing_box
  version=$(sing_box_version)
  [[ -n $version ]] || die "无法识别 sing-box 版本。"
  version_ge "$version" "$SING_BOX_MIN_VERSION" || die "sbctl 需要 sing-box >= ${SING_BOX_MIN_VERSION}（AnyTLS 从 1.12.0 起支持），当前为 ${version}。"
}

restart_service_checked() {
  service_exists || return 0
  service_restart || return 1
  sleep 0.2
  service_is_active
}

# Hardened service definition.
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
