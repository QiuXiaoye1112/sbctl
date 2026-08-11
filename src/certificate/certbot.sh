# shellcheck shell=bash
# Certbot environment hardening. Loaded after certops.sh/cloudflare.sh so it can
# replace only environment/bootstrap primitives while keeping certificate
# lifecycle logic canonical in certops.sh.

certbot_distribution_version() {
  local distribution=$1
  [[ -x $CERTBOT_VENV/bin/python ]] || return 1
  "$CERTBOT_VENV/bin/python" -c \
    'import importlib.metadata as m, sys; print(m.version(sys.argv[1]))' \
    "$distribution" 2>/dev/null
}

certbot_core_version() { certbot_distribution_version certbot; }

certbot_version_in_supported_range() {
  local version=${1:-} major minor
  [[ -n $version ]] || version=$(certbot_core_version) || return 1
  IFS=. read -r major minor _ <<<"$version"
  [[ $major =~ ^[0-9]+$ && $minor =~ ^[0-9]+$ ]] || return 1
  ((major == 5 && minor >= 4))
}

certbot_version_supported() {
  local version
  version=$(certbot_core_version) || return 1
  certbot_version_in_supported_range "$version" || return 1
  certbot_supports_ip
}

certbot_distribution_matches_core() {
  local distribution=$1 core installed
  core=$(certbot_core_version) || return 1
  installed=$(certbot_distribution_version "$distribution") || return 1
  [[ $installed == "$core" ]]
}

_certbot_report_memory() {
  local mem_total_kb mem_available_kb swap_total_kb
  [[ -r /proc/meminfo ]] || return 0
  mem_total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  mem_available_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  swap_total_kb=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
  warn "内存约 $((mem_total_kb / 1024)) MiB，可用约 $((mem_available_kb / 1024)) MiB，Swap 约 $((swap_total_kb / 1024)) MiB。"
}

certbot_pip_install() {
  local label=$1; shift
  local pip_timeout=${SBCTL_PIP_TIMEOUT:-300} log_file status
  [[ -x $CERTBOT_VENV/bin/pip ]] || { warn "Certbot venv 缺少 pip，无法安装 ${label}。"; return 1; }
  log_file=$(temp_file)
  : >"$log_file"
  if _cert_run_bounded "$pip_timeout" env \
    PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 \
    "$CERTBOT_VENV/bin/pip" install \
      --disable-pip-version-check --no-cache-dir --no-compile --prefer-binary \
      --timeout 20 --retries 2 "$@" >>"$log_file" 2>&1; then
    rm -f "$log_file"
    return 0
  else
    status=$?
  fi
  case $status in
    137)
      warn "${label} 安装进程被 SIGKILL；通常表示 VPS 内存不足并触发 OOM。"
      _certbot_report_memory
      ;;
    124) warn "${label} 安装超过 ${pip_timeout} 秒，已终止。" ;;
    *) warn "${label} 安装失败（退出码 ${status}）。" ;;
  esac
  [[ ! -s $log_file ]] || { warn "pip 最后输出："; tail -n 20 "$log_file" >&2; }
  rm -f "$log_file"
  return "$status"
}

certbot_pip_check() {
  [[ -x $CERTBOT_VENV/bin/pip ]] && "$CERTBOT_VENV/bin/pip" check >/dev/null 2>&1
}

_certbot_install_system_python() {
  local manager
  manager=$(pkg_manager) || { warn "无法准备 Certbot 环境：未知包管理器。"; return 1; }
  case $manager in
    apt) install_packages python3 python3-venv;;
    apk) install_packages python3 py3-pip py3-virtualenv;;
    dnf|yum) install_packages python3 python3-pip;;
    pacman) install_packages python python-pip;;
    zypper) install_packages python3 python3-pip;;
  esac
}

_certbot_prepare_venv() {
  local bootstrap
  install -d -m 755 "$(dirname "$CERTBOT_VENV")"

  if [[ ! -x $CERTBOT_VENV/bin/python ]]; then
    if ! command_exists python3 || ! run_bounded 120 python3 -m venv "$CERTBOT_VENV" 2>/dev/null; then
      _certbot_install_system_python || return 1
      if ! run_bounded 120 python3 -m venv "$CERTBOT_VENV" 2>/dev/null; then
        run_bounded 120 python3 -m venv --without-pip "$CERTBOT_VENV" || return 1
      fi
    fi
  fi

  if [[ ! -x $CERTBOT_VENV/bin/pip ]]; then
    "$CERTBOT_VENV/bin/python" -m ensurepip --upgrade >/dev/null 2>&1 || true
  fi
  if [[ ! -x $CERTBOT_VENV/bin/pip ]]; then
    bootstrap=$(temp_file)
    curl --fail --location --proto '=https' --tlsv1.2 --retry 2 --connect-timeout 15 --max-time 60 \
      https://bootstrap.pypa.io/get-pip.py -o "$bootstrap" || { rm -f "$bootstrap"; return 1; }
    _cert_run_bounded 120 "$CERTBOT_VENV/bin/python" "$bootstrap" --disable-pip-version-check \
      || { rm -f "$bootstrap"; return 1; }
    rm -f "$bootstrap"
  fi
  [[ -x $CERTBOT_VENV/bin/python && -x $CERTBOT_VENV/bin/pip ]]
}

_ensure_certbot_nginx_for_version() {
  local version=$1 installed="" force=0
  installed=$(certbot_distribution_version certbot-nginx 2>/dev/null || true)
  if [[ $installed == "$version" ]] && certbot_nginx_available; then return 0; fi
  [[ $installed == "$version" ]] && force=1
  info "正在安装/修复 Certbot nginx 插件。"
  if ((force)); then
    certbot_pip_install "Certbot nginx 插件" --force-reinstall "certbot-nginx==${version}" || return 1
  else
    certbot_pip_install "Certbot nginx 插件" "certbot-nginx==${version}" || return 1
  fi
  certbot_distribution_matches_core certbot-nginx && certbot_nginx_available
}

ensure_certbot_nginx_plugin() {
  local version
  if ! certbot_version_supported; then
    ensure_certbot_environment
    return $?
  fi
  version=$(certbot_core_version) || return 1
  _ensure_certbot_nginx_for_version "$version" || return 1
  certbot_pip_check || { warn "Certbot Python 依赖不一致，nginx 插件不可安全使用。"; return 1; }
}

_repair_installed_cloudflare_version() {
  local version=$1 installed
  installed=$(certbot_distribution_version certbot-dns-cloudflare 2>/dev/null || true)
  [[ -n $installed ]] || return 0
  [[ $installed == "$version" ]] && return 0
  info "检测到 Certbot Cloudflare 插件版本不一致，正在同步到 ${version}。"
  certbot_pip_install "Certbot Cloudflare DNS 插件" "certbot-dns-cloudflare==${version}"
}

ensure_certbot_environment() {
  local version cf_installed="" repair_specs=()
  _certbot_prepare_venv || die "无法创建/修复 Certbot venv。"

  if ! certbot_version_supported; then
    version=$(certbot_core_version 2>/dev/null || true)
    info "正在安装/修复 Certbot 5.x 核心。"
    if certbot_version_in_supported_range "$version"; then
      certbot_pip_install "Certbot 核心" --force-reinstall "certbot==${version}" || die "Certbot 安装失败。"
    else
      certbot_pip_install "Certbot 核心" 'certbot>=5.4,<6' || die "Certbot 安装失败。"
    fi
  fi

  certbot_version_supported || die "当前 Certbot 不受支持（需要 5.4 <= 版本 < 6）。"
  version=$(certbot_core_version) || die "无法读取 Certbot 版本。"
  _ensure_certbot_nginx_for_version "$version" || die "Certbot nginx 插件安装/修复失败。"
  _repair_installed_cloudflare_version "$version" || die "Certbot Cloudflare 插件版本修复失败。"

  if ! certbot_pip_check; then
    warn "检测到 Certbot Python 依赖不一致，正在按当前版本修复依赖。"
    repair_specs+=("certbot==${version}" "certbot-nginx==${version}")
    cf_installed=$(certbot_distribution_version certbot-dns-cloudflare 2>/dev/null || true)
    [[ -z $cf_installed ]] || repair_specs+=("certbot-dns-cloudflare==${version}")
    certbot_pip_install "Certbot Python 依赖" "${repair_specs[@]}" || die "Certbot Python 依赖修复失败。"
    certbot_pip_check || die "Certbot Python 依赖仍不一致，请检查 pip check 输出。"
  fi

  certbot_distribution_matches_core certbot-nginx || die "Certbot nginx 插件版本与 Certbot 核心不一致。"
  certbot_nginx_available || die "Certbot nginx 插件不可用，请重新准备证书环境。"
  mkdir -p "$CERTBOT_CONFIG_DIR" "$CERTBOT_WORK_DIR" "$CERTBOT_LOGS_DIR"
  meta_resource_register certbotVenv "$CERTBOT_VENV"
  meta_resource_register certbotConfigDir "$CERTBOT_CONFIG_DIR"
  meta_resource_register certbotWorkDir "$CERTBOT_WORK_DIR"
  meta_resource_register certbotLogsDir "$CERTBOT_LOGS_DIR"
}

_certbot_exec() {
  "$CERTBOT_BIN" --config-dir "$CERTBOT_CONFIG_DIR" --work-dir "$CERTBOT_WORK_DIR" --logs-dir "$CERTBOT_LOGS_DIR" "$@"
}

_certbot_shared_lock_acquire() {
  local waited=0 owner="" lock=$CERTBOT_SHARED_LOCK parent
  [[ ${lock##*/} == xrayctl-sbctl-certbot.lock ]] || { error "Certbot 共享锁路径不安全：${lock}"; return 1; }
  [[ $CERTBOT_SHARED_LOCK_WAIT =~ ^[0-9]+$ ]] || { error "Certbot 共享锁等待时间无效。"; return 1; }
  parent=${lock%/*}; [[ $parent == "$lock" ]] && parent=.
  mkdir -p "$parent" || { warn "无法创建 Certbot 共享锁目录：${parent}"; return 1; }
  while ! mkdir "$lock" 2>/dev/null; do
    owner=""
    [[ -r $lock/pid ]] && IFS= read -r owner <"$lock/pid" || true
    if [[ $owner =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
      rm -f "$lock/pid" "$lock/tool"
      rmdir "$lock" 2>/dev/null || true
      continue
    fi
    if ((waited >= CERTBOT_SHARED_LOCK_WAIT)); then
      warn "另一个 xrayctl/sbctl Certbot 操作仍在运行，当前操作已取消。"
      return 1
    fi
    sleep 1
    ((waited+=1)) || true
  done
  chmod 700 "$lock" 2>/dev/null || true
  printf '%s\n' "$$" >"$lock/pid"
  printf 'sbctl\n' >"$lock/tool"
}

_certbot_shared_lock_release() {
  local owner="" lock=$CERTBOT_SHARED_LOCK
  [[ -r $lock/pid ]] && IFS= read -r owner <"$lock/pid" || true
  [[ $owner == "$$" ]] || return 0
  rm -f "$lock/pid" "$lock/tool"
  rmdir "$lock" 2>/dev/null || true
}

_certbot_arg_value() {
  local wanted=$1; shift
  while (($#)); do
    if [[ $1 == "$wanted" && $# -ge 2 ]]; then printf '%s' "$2"; return 0; fi
    shift
  done
  return 1
}

_certbot_renewal_authenticator() {
  local cert_name=$1 conf="$CERTBOT_CONFIG_DIR/renewal/${cert_name}.conf"
  [[ -r $conf ]] || return 1
  sed -n 's/^[[:space:]]*authenticator[[:space:]]*=[[:space:]]*//p' "$conf" | sed -n '1p'
}

# Keep certops.sh's public command surface, but self-heal the nginx plugin before
# an unattended renewal whose lineage explicitly records the nginx authenticator.
certbot_cmd() {
  local cert_name="" authenticator="" rc=0
  if [[ ${1:-} == renew ]]; then
    cert_name=$(_certbot_arg_value --cert-name "$@" 2>/dev/null || true)
    if [[ -n $cert_name ]]; then
      authenticator=$(_certbot_renewal_authenticator "$cert_name" 2>/dev/null || true)
      if [[ $authenticator == nginx ]]; then
        ensure_certbot_nginx_plugin || { warn "${cert_name}: Certbot nginx 插件无法修复，续期已停止。"; return 1; }
      fi
    fi
  fi
  _certbot_shared_lock_acquire || return 1
  _certbot_exec "$@" || rc=$?
  _certbot_shared_lock_release
  return "$rc"
}
