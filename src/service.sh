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
  if traffic_is_enabled; then printf '流量统计: 运行中（%s）\n' "$(traffic_backend)"; else printf '流量统计: 已停止\n'; fi
  if traffic_limits_are_enabled; then printf '流量限制: 已启用（%s 个入站）\n' "$(traffic_limit_count)"; else printf '流量限制: 未启用\n'; fi
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

sing_box_release_platform() {
  local version=$1 arch=$2
  # Modern generic archives can depend on a companion libcronet.so. Prefer
  # the official static musl build where it exists so the managed core remains
  # a single, portable binary on every distribution.
  if version_ge "$version" 1.13.3; then
    case $arch in
      amd64|arm64|armv7|386|riscv64) printf 'linux-%s-musl' "$arch"; return 0 ;;
    esac
  fi
  printf 'linux-%s' "$arch"
}

resolve_sing_box_version() {
  local requested=${1-} payload resolved
  if [[ -n $requested ]]; then
    resolved=${requested#v}
  else
    payload=$(curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 1 \
      --connect-timeout 10 --max-time 60 "$SING_BOX_RELEASE_API") || {
      error "无法获取 sing-box 最新 stable Release。"
      return 1
    }
    resolved=$(jq -r 'select(.draft==false and .prerelease==false) | .tag_name // empty' <<<"$payload")
    resolved=${resolved#v}
  fi
  [[ $resolved =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    error "无效或非 stable 的 sing-box 版本：${resolved:-未知}"
    return 1
  }
  printf '%s' "$resolved"
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

find_external_sing_box() {
  command -v sing-box 2>/dev/null || true
}

create_sing_box_work_dir() {
  local base=${SBCTL_TMP_DIR:-/var/tmp}
  mkdir -p "$base" || return 1
  mktemp -d "$base/sbctl-sing-box.XXXXXX"
}

ensure_sing_box_install_target_safe() {
  local target=$SING_BOX_RELEASE_INSTALL_PATH expected actual external
  [[ $target == /usr/local/bin/sing-box || ${SBCTL_TESTING:-0} == 1 ]] || {
    error "sing-box 受管安装路径必须是 /usr/local/bin/sing-box。"
    return 1
  }
  [[ ! -d $target && ! -L $target ]] || { error "拒绝覆盖非普通文件：${target}"; return 1; }
  if [[ -e $target ]]; then
    _sing_box_target_is_managed || {
      error "${target} 已存在，但 metadata 无法确认由 sbctl 管理；拒绝覆盖。"
      return 1
    }
    expected=$(_sing_box_meta_get sha256)
    actual=$(_sing_box_binary_sha256 "$target") || true
    [[ -n $expected && $actual == "$expected" ]] || {
      error "${target} 已被修改，与 sbctl metadata 不一致；拒绝覆盖。"
      return 1
    }
    return 0
  fi
  external=$(find_external_sing_box)
  if [[ -n $external && $external != "$target" ]]; then
    error "检测到外部 sing-box：${external}；请先明确迁移或移除后再由 sbctl 管理。"
    return 1
  fi
}

download_sing_box_release() {
  local version=$1 arch=$2 work_dir=$3 platform archive_name archive_url archive member
  platform=$(sing_box_release_platform "$version" "$arch")
  archive_name="sing-box-${version}-${platform}.tar.gz"
  archive_url="${SING_BOX_RELEASE_DOWNLOAD_BASE}/v${version}/${archive_name}"
  archive="${work_dir}/${archive_name}"
  member="sing-box-${version}-${platform}/sing-box"
  if ! curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 1 \
    --connect-timeout 10 --max-time 120 "$archive_url" -o "$archive"; then
    error "sing-box 官方 Release 不存在或下载失败：${archive_url}"
    return 1
  fi
  if ! tar -tzf "$archive" "$member" >/dev/null 2>&1 || ! tar -xzf "$archive" -C "$work_dir" "$member"; then
    error "sing-box 官方 Release 压缩包损坏或缺少 binary。"
    return 1
  fi
  SING_BOX_DOWNLOADED_BINARY="${work_dir}/${member}"
  SING_BOX_DOWNLOADED_PLATFORM=$platform
}

verify_sing_box_binary() {
  local candidate=$1 expected_version=$2 output status=0 actual_version
  [[ -f $candidate && ! -L $candidate ]] || { error "sing-box Release 候选 binary 无效。"; return 1; }
  chmod 755 "$candidate" || return 1
  if output=$("$candidate" version 2>&1); then :; else status=$?; fi
  actual_version=$(printf '%s\n' "$output" \
    | sed -n 's/^sing-box version \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' \
    | head -n 1)
  if ((status != 0)) || [[ -z $actual_version || $actual_version != "$expected_version" ]]; then
    error "sing-box Release binary 校验失败（期望 ${expected_version}，实际 ${actual_version:-无法识别}，退出码 ${status}）。"
    [[ -z $output ]] || error "候选 binary 输出：$(printf '%s' "$output" | head -n 1)"
    return 1
  fi
  version_ge "$actual_version" "$SING_BOX_MIN_VERSION" || {
    error "sbctl 需要 sing-box >= ${SING_BOX_MIN_VERSION}，当前候选版本为 ${actual_version}。"
    return 1
  }
  SING_BOX_VERIFIED_VERSION=$actual_version
  SING_BOX_VERIFIED_SHA256=$(_sing_box_binary_sha256 "$candidate") || return 1
}

rollback_sing_box_binary() {
  local target=$1 backup=${2-} had_old=${3:-0} staged
  if ((had_old)); then
    [[ -f $backup ]] || { error "旧 sing-box binary 备份丢失，无法回滚。"; return 1; }
    staged=$(mktemp "${target%/*}/.sing-box.rollback.XXXXXX") || return 1
    install -m 755 "$backup" "$staged" && mv -f -- "$staged" "$target" || { rm -f -- "$staged"; return 1; }
  else
    rm -f -- "$target"
  fi
  sbc_invalidate_install_cache
  refresh_binary_path
}

wait_for_sing_box_service() {
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    service_is_active && return 0
    sleep 0.25
  done
  return 1
}

install_sing_box_release() {
  local requested=${1-} version arch work_dir target target_dir candidate staged backup="" meta_snapshot config_snapshot
  local service_definition="" service_snapshot=""
  local had_old=0 had_meta=0 had_config=0 old_service_exists=0 old_active=0 old_enabled=0 had_service_definition=0 failed=0

  ensure_sing_box_install_target_safe || return 1
  version=$(resolve_sing_box_version "$requested") || return 1
  arch=$(detect_sing_box_arch) || return 1
  work_dir=$(create_sing_box_work_dir) || { error "无法创建 sing-box 临时目录。"; return 1; }
  SING_BOX_DOWNLOADED_BINARY=""; SING_BOX_DOWNLOADED_PLATFORM=""
  if ! download_sing_box_release "$version" "$arch" "$work_dir"; then rm -rf -- "$work_dir"; return 1; fi
  candidate=$SING_BOX_DOWNLOADED_BINARY
  if ! verify_sing_box_binary "$candidate" "$version"; then rm -rf -- "$work_dir"; return 1; fi
  if [[ -f $CONFIG_FILE ]] && ! "$candidate" check -c "$CONFIG_FILE" >/dev/null 2>&1; then
    rm -rf -- "$work_dir"; error "新 sing-box 核心无法通过当前配置检查，未替换旧核心。"; return 1
  fi

  target=$SING_BOX_RELEASE_INSTALL_PATH; target_dir=${target%/*}
  mkdir -p "$target_dir" || { rm -rf -- "$work_dir"; return 1; }
  if [[ -f $target ]]; then
    had_old=1; backup=$(mktemp "${target_dir}/.sing-box.backup.XXXXXX") || { rm -rf -- "$work_dir"; return 1; }
    cp -p "$target" "$backup" || { rm -f -- "$backup"; rm -rf -- "$work_dir"; return 1; }
  fi
  meta_snapshot=$(temp_file)
  if [[ -f $META_FILE ]]; then cp -p "$META_FILE" "$meta_snapshot"; had_meta=1; fi
  config_snapshot=$(temp_file)
  if [[ -f $CONFIG_FILE ]]; then cp -p "$CONFIG_FILE" "$config_snapshot"; had_config=1; fi
  service_exists && old_service_exists=1
  service_is_active && old_active=1
  service_is_enabled && old_enabled=1
  case $(init_system) in
    systemd) service_definition="${SYSTEMD_UNIT_DIR}/${SERVICE_NAME}.service" ;;
    openrc) service_definition="${OPENRC_INIT_DIR}/${SERVICE_NAME}" ;;
  esac
  if [[ -n $service_definition && -f $service_definition ]]; then
    service_snapshot=$(temp_file); cp -p "$service_definition" "$service_snapshot"; had_service_definition=1
  fi

  staged=$(mktemp "${target_dir}/.sing-box.install.XXXXXX") || failed=1
  if ((failed == 0)); then install -m 755 "$candidate" "$staged" || failed=1; fi
  if ((failed == 0)); then mv -f -- "$staged" "$target" || failed=1; fi
  rm -f -- "$staged" 2>/dev/null || true
  if ((failed == 0)); then
    sbc_invalidate_install_cache; refresh_binary_path
    if ((had_config)); then ensure_config; else write_default_config; fi
    validate_candidate "$CONFIG_FILE" || failed=1
  fi
  if ((failed == 0)); then _record_sing_box_install "$version" "$arch" "$SING_BOX_VERIFIED_SHA256" "$SING_BOX_DOWNLOADED_PLATFORM" || failed=1; fi
  if ((failed == 0)); then create_service_definition || failed=1; fi
  if ((failed == 0)); then install_quick_command || failed=1; fi
  if ((failed == 0)); then service_enable || failed=1; fi
  if ((failed == 0)); then
    if ((old_active)); then service_restart || failed=1; else service_start || failed=1; fi
  fi
  if ((failed == 0)) && ! wait_for_sing_box_service; then failed=1; fi

  if ((failed)); then
    error "新 sing-box 核心未能正常接管服务，正在回滚。"
    rollback_sing_box_binary "$target" "$backup" "$had_old" || error "sing-box binary 自动回滚失败。"
    if ((had_meta)); then install -m 600 "$meta_snapshot" "$META_FILE"; else rm -f "$META_FILE"; fi
    if ((had_config)); then install -m 600 "$config_snapshot" "$CONFIG_FILE"; else rm -f "$CONFIG_FILE"; fi
    if ((had_service_definition)); then
      cp -p "$service_snapshot" "$service_definition"
      [[ $(init_system) != systemd ]] || systemctl daemon-reload >/dev/null 2>&1 || true
    else
      _remove_sbctl_service_definition
    fi
    if ((old_service_exists && old_active)); then service_restart >/dev/null 2>&1 || true; else service_stop >/dev/null 2>&1 || true; fi
    if ((old_enabled)); then service_enable >/dev/null 2>&1 || true; else service_disable >/dev/null 2>&1 || true; fi
    rm -f -- "$backup" "$meta_snapshot" "$config_snapshot" "$service_snapshot"; rm -rf -- "$work_dir"
    return 1
  fi

  rm -f -- "$backup" "$meta_snapshot" "$config_snapshot" "$service_snapshot"; rm -rf -- "$work_dir"
  info "已通过 SagerNet 官方 GitHub Release 安装 sing-box ${version}（${arch}）。"
}

require_sing_box() { refresh_binary_path; sing_box_installed || die "sing-box 尚未安装，请先运行 sbctl install。"; }

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
  install_sing_box_release "${1-}" || die "sing-box 官方 Release 安装/更新失败；原核心与服务已保留。"
  if traffic_is_enabled; then
    traffic_runtime_ensure || warn "sing-box 已安装，但流量统计运行时恢复失败。"
  fi
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
