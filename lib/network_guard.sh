# shellcheck shell=bash
# Network, package-manager and Certbot reliability policy.

run_bounded() {
  local seconds=$1; shift
  if command_exists timeout; then timeout "$seconds" "$@"; else "$@"; fi
}
_cert_run_bounded() { run_bounded "$@"; }

apt_ipv4_available() {
  if [[ -n ${APT_IPV4_AVAILABLE_CACHE:-} ]]; then
    [[ $APT_IPV4_AVAILABLE_CACHE == 1 ]]
    return
  fi
  local available=0
  if command_exists ip && ip -4 route get 1.1.1.1 >/dev/null 2>&1; then
    available=1
  elif [[ -r /proc/net/route ]] && awk '$2=="00000000" && $4 ~ /0003/ {found=1} END{exit !found}' /proc/net/route 2>/dev/null; then
    available=1
  fi
  APT_IPV4_AVAILABLE_CACHE=$available
  ((available == 1))
}

apt_get_guarded() {
  local total_timeout=${SBCTL_APT_TIMEOUT:-180}
  local apt_options=(
    -o Acquire::Retries=2
    -o Acquire::http::Timeout=15
    -o Acquire::https::Timeout=15
    -o Dpkg::Use-Pty=0
  )
  apt_ipv4_available && apt_options+=(-o Acquire::ForceIPv4=true)
  run_bounded "$total_timeout" apt-get "${apt_options[@]}" "$@"
}

install_packages() {
  local manager
  manager=$(pkg_manager) || die "无法识别包管理器。"
  case $manager in
    apk) run_bounded 180 apk add --no-cache "$@" ;;
    apt)
      if ! DEBIAN_FRONTEND=noninteractive apt_get_guarded update -y; then
        warn "APT 软件索引更新失败或超时，尝试使用现有索引继续安装。"
      fi
      DEBIAN_FRONTEND=noninteractive apt_get_guarded install -y --no-install-recommends "$@" \
        || die "APT 依赖安装失败，请检查软件源、DNS 和服务器网络。"
      ;;
    dnf) run_bounded 180 dnf install -y "$@" ;;
    yum) run_bounded 180 yum install -y "$@" ;;
    pacman) run_bounded 180 pacman -Sy --noconfirm --needed "$@" ;;
    zypper) run_bounded 180 zypper --non-interactive install "$@" ;;
  esac
}

detect_public_ipv4() {
  local response raw
  command_exists curl || return 1
  response=$({ curl -4 --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null || true; } | tr -d '[:space:]')
  if validate_ipv4 "$response"; then printf '%s' "$response"; return 0; fi
  response=$({ curl -4 --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 3 --max-time 5 https://checkip.amazonaws.com 2>/dev/null || true; } | tr -d '[:space:]')
  if validate_ipv4 "$response"; then printf '%s' "$response"; return 0; fi
  raw=$(curl -4 --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 3 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
  response=$(awk -F= '$1=="ip" {print $2; exit}' <<<"$raw" | tr -d '[:space:]')
  if validate_ipv4 "$response"; then printf '%s' "$response"; return 0; fi
  return 1
}

detect_public_ipv6() {
  local response raw
  command_exists curl || return 1
  response=$({ curl -6 --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 3 --max-time 5 https://api6.ipify.org 2>/dev/null || true; } | tr -d '[:space:]')
  if validate_ip_literal "$response" && ! validate_ipv4 "$response"; then printf '%s' "$response"; return 0; fi
  raw=$(curl -6 --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 3 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
  response=$(awk -F= '$1=="ip" {print $2; exit}' <<<"$raw" | tr -d '[:space:]')
  if validate_ip_literal "$response" && ! validate_ipv4 "$response"; then printf '%s' "$response"; return 0; fi
  return 1
}

prompt_public_host() {
  local __var=$1 default=${2:-} v4="" v6="" choice value=""
  if [[ -z $default ]]; then
    v4=$(detect_public_ipv4 || true)
    v6=$(detect_public_ipv6 || true)
    if [[ -n $v4 && -n $v6 ]]; then
      choose choice "选择客户端连接地址" "IPv4  $v4" "IPv6  $v6" "域名/其他地址" || return 1
      case $choice in
        1) value=$v4;;
        2) value=$v6;;
        3) prompt_value value "客户端连接域名/IP" || return 1;;
      esac
    elif [[ -n $v4 ]]; then value=$v4
    elif [[ -n $v6 ]]; then value=$v6
    else prompt_value value "客户端连接域名/IP" || return 1
    fi
  else
    value=$default
  fi
  [[ -n $value && $value != *' '* ]] || { error "客户端连接地址无效。"; return 1; }
  printf -v "$__var" '%s' "$value"
}

ensure_certbot_environment() {
  local manager need_install=0
  if [[ ! -x $CERTBOT_BIN ]] || ! certbot_supports_ip; then need_install=1; fi
  if ((need_install)); then
    manager=$(pkg_manager) || die "无法准备 Certbot 环境：未知包管理器。"
    info "正在准备 sbctl 独立 Certbot 环境。"
    case $manager in
      apt) install_packages python3 python3-venv;;
      apk) install_packages python3 py3-pip py3-virtualenv;;
      dnf|yum) install_packages python3 python3-pip;;
      pacman) install_packages python python-pip;;
      zypper) install_packages python3 python3-pip;;
    esac
    install -d -m 755 "$(dirname "$CERTBOT_VENV")"
    if [[ ! -x $CERTBOT_VENV/bin/python ]]; then
      if ! python3 -m venv "$CERTBOT_VENV" 2>/dev/null; then
        python3 -m venv --without-pip "$CERTBOT_VENV" || die "无法创建 Certbot venv。"
        local bootstrap
        bootstrap=$(temp_file)
        curl --fail --location --proto '=https' --tlsv1.2 --retry 2 --connect-timeout 15 --max-time 60 \
          https://bootstrap.pypa.io/get-pip.py -o "$bootstrap" || { rm -f "$bootstrap"; die "下载 pip 引导脚本失败。"; }
        run_bounded 120 "$CERTBOT_VENV/bin/python" "$bootstrap" --disable-pip-version-check \
          || { rm -f "$bootstrap"; die "pip 引导安装失败。"; }
        rm -f "$bootstrap"
      fi
    fi
    run_bounded 180 "$CERTBOT_VENV/bin/pip" install --disable-pip-version-check --timeout 20 --retries 2 \
      --upgrade 'certbot>=5.4' certbot-nginx >/dev/null || die "Certbot 安装失败。"
  fi
  certbot_supports_ip || die "当前 Certbot 不支持公网 IP 证书（需要 Certbot 5.4+）。"
  mkdir -p "$CERTBOT_CONFIG_DIR" "$CERTBOT_WORK_DIR" "$CERTBOT_LOGS_DIR"
  meta_resource_register certbotVenv "$CERTBOT_VENV"
  meta_resource_register certbotConfigDir "$CERTBOT_CONFIG_DIR"
  meta_resource_register certbotWorkDir "$CERTBOT_WORK_DIR"
  meta_resource_register certbotLogsDir "$CERTBOT_LOGS_DIR"
}

certbot_account_ids() {
  local file id
  local files=("$CERTBOT_CONFIG_DIR"/accounts/*/*/*/regr.json)
  declare -A seen=()
  for file in "${files[@]}"; do
    [[ -f $file ]] || continue
    id=$(basename "$(dirname "$file")")
    [[ -n ${seen[$id]:-} ]] && continue
    seen[$id]=1
    printf '%s\n' "$id"
  done
}

certbot_account_exists() {
  local wanted=$1 id
  while IFS= read -r id; do [[ $id == "$wanted" ]] && return 0; done < <(certbot_account_ids)
  return 1
}

certbot_lineage_account() {
  local cert_name=$1
  local conf="$CERTBOT_CONFIG_DIR/renewal/${cert_name}.conf"
  [[ -r $conf ]] || return 1
  sed -n 's/^[[:space:]]*account[[:space:]]*=[[:space:]]*//p' "$conf" | sed -n '1p'
}

select_certbot_account() {
  local __var=$1 cert_name=${2:-} configured=${SBCTL_CERTBOT_ACCOUNT:-} lineage="" id answer
  local ids=()
  if [[ -n $cert_name ]]; then
    lineage=$(certbot_lineage_account "$cert_name" 2>/dev/null || true)
    if [[ -n $lineage ]]; then
      if certbot_account_exists "$lineage"; then printf -v "$__var" '%s' "$lineage"; return 0; fi
      warn "证书 ${cert_name} 记录的 Certbot 账户 ${lineage} 已不存在。"
    fi
  fi
  if [[ -n $configured ]]; then
    certbot_account_exists "$configured" || { warn "SBCTL_CERTBOT_ACCOUNT 指定的账户不存在：$configured"; return 1; }
    printf -v "$__var" '%s' "$configured"
    return 0
  fi
  while IFS= read -r id; do [[ -n $id ]] && ids+=("$id"); done < <(certbot_account_ids)
  case ${#ids[@]} in
    0) printf -v "$__var" '%s' ""; return 0;;
    1) printf -v "$__var" '%s' "${ids[0]}"; return 0;;
  esac
  if [[ ! -t 0 ]]; then
    warn "检测到多个 Certbot 账户；非交互模式请设置 SBCTL_CERTBOT_ACCOUNT=<账户ID>。"
    return 1
  fi
  choose answer "选择 Let's Encrypt / Certbot 账户" "${ids[@]}" || return 1
  printf -v "$__var" '%s' "${ids[$((answer-1))]}"
}

certbot_issue_cmd() {
  local cert_name=$1; shift
  local account="" args=("$@")
  select_certbot_account account "$cert_name" || return 1
  [[ -z $account ]] || args+=(--account "$account")
  certbot_cmd "${args[@]}"
}

_issue_domain_http() {
  local domain=$1 email=$2 force=$3 __validation=$4 owner was_active=0
  owner=$(detect_port80_owner)
  local args=(certonly --non-interactive --agree-tos --cert-name "$domain" -m "$email" -d "$domain")
  [[ $force == 1 ]] && args+=(--force-renewal)
  case $owner in
    free)
      args+=(--standalone --preferred-challenges http)
      printf -v "$__validation" '%s' http-standalone
      certbot_issue_cmd "$domain" "${args[@]}"
      ;;
    sing-box)
      if service_is_active; then was_active=1; service_stop; CERT_STOPPED_SERVICE=1; fi
      args+=(--standalone --preferred-challenges http)
      printf -v "$__validation" '%s' http-standalone
      if ! certbot_issue_cmd "$domain" "${args[@]}"; then
        if ((was_active)); then service_start || true; CERT_STOPPED_SERVICE=0; fi
        return 1
      fi
      if ((was_active)); then service_start; CERT_STOPPED_SERVICE=0; fi
      ;;
    nginx)
      printf -v "$__validation" '%s' nginx
      local nginx_args=(certonly --nginx --non-interactive --agree-tos --cert-name "$domain" -m "$email" -d "$domain")
      [[ $force == 1 ]] && nginx_args+=(--force-renewal)
      certbot_issue_cmd "$domain" "${nginx_args[@]}"
      ;;
    apache) warn "80 端口被 Apache 占用；请改用 DNS 验证。"; return 1;;
    *) warn "80 端口被其他程序占用或无法识别；请改用 DNS 验证。"; return 1;;
  esac
}

_issue_domain_manual_dns() {
  local domain=$1 email=$2 force=$3
  local args=(certonly --manual --agree-tos --cert-name "$domain" -m "$email" --preferred-challenges dns -d "$domain")
  [[ $force == 1 ]] && args+=(--force-renewal)
  info "Certbot 将提示添加 TXT 记录；验证完成后该证书不会被标记为自动续期。"
  certbot_issue_cmd "$domain" "${args[@]}"
}

_issue_ip_certificate() {
  local ip=$1 email=$2 force=$3 identifier owner was_active=0
  identifier=$(certificate_identifier_for_subject "$ip")
  owner=$(detect_port80_owner)
  local args=(certonly --standalone --non-interactive --agree-tos --preferred-challenges http \
    --cert-name "$identifier" -m "$email" --preferred-profile shortlived --ip-address "$ip")
  [[ $force == 1 ]] && args+=(--force-renewal)
  case $owner in
    free) certbot_issue_cmd "$identifier" "${args[@]}";;
    sing-box)
      if service_is_active; then was_active=1; service_stop; CERT_STOPPED_SERVICE=1; fi
      if ! certbot_issue_cmd "$identifier" "${args[@]}"; then
        if ((was_active)); then service_start || true; CERT_STOPPED_SERVICE=0; fi
        return 1
      fi
      if ((was_active)); then service_start; CERT_STOPPED_SERVICE=0; fi
      ;;
    *) warn "公网 IP 证书必须使用 80 端口 HTTP 验证，但端口 80 当前不可用。"; return 1;;
  esac
}

_issue_domain_cloudflare() {
  local domain=$1 email=$2 force=$3
  load_cloudflare_credentials || { warn "Cloudflare 邮箱 / Global API Key 未配置。"; return 1; }
  ensure_cloudflare_certbot_plugin || return 1
  local args=(certonly --dns-cloudflare --dns-cloudflare-credentials "$CLOUDFLARE_INI" \
    --dns-cloudflare-propagation-seconds 10 --non-interactive --agree-tos --cert-name "$domain" -m "$email" -d "$domain")
  [[ $force == 1 ]] && args+=(--force-renewal)
  certbot_issue_cmd "$domain" "${args[@]}"
}
