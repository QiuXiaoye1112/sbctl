# Cross-cutting reliability and safety hardening for sbctl.
# Loaded last so these policies apply consistently to all existing modules.

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
    elif [[ -n $v4 ]]; then
      value=$v4
    elif [[ -n $v6 ]]; then
      value=$v6
    else
      prompt_value value "客户端连接域名/IP" || return 1
    fi
  else
    value=$default
  fi
  [[ -n $value && $value != *' '* ]] || { error "客户端连接地址无效。"; return 1; }
  printf -v "$__var" '%s' "$value"
}

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
  local cert_name=$1 conf="$CERTBOT_CONFIG_DIR/renewal/${cert_name}.conf"
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
      service_is_active && { was_active=1; service_stop; CERT_STOPPED_SERVICE=1; }
      args+=(--standalone --preferred-challenges http)
      printf -v "$__validation" '%s' http-standalone
      if ! certbot_issue_cmd "$domain" "${args[@]}"; then
        ((was_active)) && { service_start || true; CERT_STOPPED_SERVICE=0; }
        return 1
      fi
      ((was_active)) && { service_start; CERT_STOPPED_SERVICE=0; }
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
      service_is_active && { was_active=1; service_stop; CERT_STOPPED_SERVICE=1; }
      if ! certbot_issue_cmd "$identifier" "${args[@]}"; then
        ((was_active)) && { service_start || true; CERT_STOPPED_SERVICE=0; }
        return 1
      fi
      ((was_active)) && { service_start; CERT_STOPPED_SERVICE=0; }
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

apply_candidate_with_meta() {
  local candidate=$1 meta_candidate=${2:-} cfg_rollback meta_rollback old_active=0 had_meta=0 failed=0
  ensure_config
  validate_candidate "$candidate" || return 1
  if [[ -n $meta_candidate ]]; then
    jq -e 'type=="object" and ((.inbounds // {})|type=="object")' "$meta_candidate" >/dev/null \
      || { error "metadata 候选文件无效。"; return 1; }
  fi
  service_is_active && old_active=1
  cfg_rollback=$(temp_file); cp -a "$CONFIG_FILE" "$cfg_rollback"
  meta_rollback=$(temp_file)
  if [[ -f $META_FILE ]]; then cp -a "$META_FILE" "$meta_rollback"; had_meta=1; fi
  install -m 600 "$candidate" "$CONFIG_FILE" || failed=1
  if ((failed == 0)) && [[ -n $meta_candidate ]]; then install -m 600 "$meta_candidate" "$META_FILE" || failed=1; fi
  if ((failed == 0 && old_active)) && ! restart_service_checked; then failed=1; fi
  if ((failed)); then
    error "状态应用失败，正在回滚 config/meta。"
    install -m 600 "$cfg_rollback" "$CONFIG_FILE" || true
    if ((had_meta)); then install -m 600 "$meta_rollback" "$META_FILE" || true; else rm -f "$META_FILE"; fi
    ((old_active)) && service_restart >/dev/null 2>&1 || true
    rm -f "$cfg_rollback" "$meta_rollback"
    return 1
  fi
  rm -f "$cfg_rollback" "$meta_rollback"
  info "配置已应用。"
}

apply_candidate() { apply_candidate_with_meta "$1"; }

build_inbound_meta_candidate() {
  local tag=$1 host=$2 public_key=${3-} config_candidate=$4 output=$5 private="" private_sha=""
  init_meta
  if [[ -n $public_key ]]; then
    private=$(jq -r --arg tag "$tag" '.inbounds[]?|select(.tag==$tag)|.tls.reality.private_key // empty' "$config_candidate" 2>/dev/null || true)
    [[ -z $private ]] || private_sha=$(printf '%s' "$private" | openssl dgst -sha256 -r | awk '{print $1}')
  fi
  jq --arg tag "$tag" --arg host "$host" --arg public "$public_key" --arg privateSHA "$private_sha" \
     --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
    .inbounds[$tag]=((.inbounds[$tag]//{})+{host:$host,updatedAt:$now}) |
    if $public!="" and $privateSHA!="" then
      .inbounds[$tag].realityPublicKey=$public | .inbounds[$tag].realityPrivateSHA256=$privateSHA
    else
      del(.inbounds[$tag].realityPublicKey,.inbounds[$tag].realityPrivateSHA256)
    end' "$META_FILE" >"$output"
}

add_inbound() {
  ensure_dependencies inbound-add; require_supported_core; ensure_config
  local inbound host public tag tmp meta_tmp
  build_inbound inbound host public
  tag=$(jq -r '.tag' <<<"$inbound")
  tmp=$(temp_file); meta_tmp=$(temp_file)
  jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" >"$tmp"
  build_inbound_meta_candidate "$tag" "$host" "$public" "$tmp" "$meta_tmp"
  if apply_candidate_with_meta "$tmp" "$meta_tmp"; then
    heading "入站已创建"
    show_inbound "$tag"
    print_share "$tag" "" || true
  fi
  rm -f "$tmp" "$meta_tmp"
}

modify_inbound_basic() {
  ensure_dependencies inbound-modify; ensure_config
  local tag=${1-} listen port host public tmp meta_tmp
  [[ -n $tag ]] || select_inbound tag || return
  inbound_exists "$tag" || die "找不到入站：$tag"
  prompt_value listen "监听地址" "$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen // "0.0.0.0"' "$CONFIG_FILE")"
  prompt_port port "$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.listen_port' "$CONFIG_FILE")" "$tag"
  prompt_public_host host "$(public_host_for_tag "$tag")"
  public=$(jq -r --arg tag "$tag" '.inbounds[$tag].realityPublicKey // empty' "$META_FILE" 2>/dev/null || true)
  tmp=$(temp_file); meta_tmp=$(temp_file)
  jq --arg tag "$tag" --arg listen "$listen" --argjson port "$port" '(.inbounds[]|select(.tag==$tag)) |= (.listen=$listen | .listen_port=$port)' "$CONFIG_FILE" >"$tmp"
  build_inbound_meta_candidate "$tag" "$host" "$public" "$tmp" "$meta_tmp"
  apply_candidate_with_meta "$tmp" "$meta_tmp" || true
  rm -f "$tmp" "$meta_tmp"
}

modify_inbound_security() {
  ensure_dependencies inbound-security; require_supported_core; ensure_config
  local tag=${1-} type choice tls="" public="" tmp meta_tmp host
  [[ -n $tag ]] || select_inbound tag || return
  inbound_exists "$tag" || die "找不到入站：$tag"
  type=$(jq -r --arg tag "$tag" '.inbounds[]|select(.tag==$tag)|.type' "$CONFIG_FILE")
  case $type in
    anytls|vless|trojan)
      choose choice "选择 TLS 安全层" "REALITY" "证书 TLS"
      if [[ $choice == 1 ]]; then build_reality_tls tls public; else build_certificate_tls tls; fi
      ;;
    hysteria2)
      info "Hysteria2 必须使用证书 TLS。"
      build_certificate_tls tls
      ;;
    *) die "${type} 入站没有 sbctl 可管理的 TLS/REALITY 安全层。";;
  esac
  host=$(public_host_for_tag "$tag" || true)
  [[ -n $host ]] || prompt_public_host host
  tmp=$(temp_file); meta_tmp=$(temp_file)
  jq --arg tag "$tag" --argjson tls "$tls" --arg type "$type" '
    (.inbounds[]|select(.tag==$tag)|.tls)=$tls |
    if $type=="vless" then
      (.inbounds[]|select(.tag==$tag)|.users) |= map(.flow=(if $tls.reality.enabled==true then "xtls-rprx-vision" else "" end))
    else . end' "$CONFIG_FILE" >"$tmp"
  build_inbound_meta_candidate "$tag" "$host" "$public" "$tmp" "$meta_tmp"
  if apply_candidate_with_meta "$tmp" "$meta_tmp"; then info "入站 ${tag} 的安全方式已更新。"; fi
  rm -f "$tmp" "$meta_tmp"
}

rename_inbound() {
  ensure_dependencies inbound-rename; ensure_config
  local old=${1-} new=${2-} tmp meta_tmp
  [[ -n $old ]] || select_inbound old || return
  inbound_exists "$old" || die "找不到入站：$old"
  if [[ -z $new ]]; then
    while true; do
      prompt_value new "新入站名称" "$old"
      [[ $new == "$old" ]] && { info "名称未更改。"; return 0; }
      validate_tag "$new" || { warn "标签只能包含字母、数字、点、下划线和横线。"; continue; }
      if inbound_exists "$new" || outbound_exists "$new"; then warn "标签已存在，请重新输入。"; continue; fi
      break
    done
  fi
  validate_tag "$new" || die "标签格式无效。"
  inbound_exists "$new" && die "入站标签已存在：$new"
  outbound_exists "$new" && die "出站标签已存在：$new"
  tmp=$(temp_file); meta_tmp=$(temp_file); init_meta
  jq --arg old "$old" --arg new "$new" '
    (.inbounds[]|select(.tag==$old)|.tag)=$new |
    .route.rules = [(.route.rules // [])[]? |
      if ((.inbound // null)|type)=="array" then
        .inbound |= map(if .==$old then $new else . end)
      elif (.inbound // null)==$old then .inbound=$new
      else . end]' "$CONFIG_FILE" >"$tmp"
  jq --arg old "$old" --arg new "$new" 'if .inbounds[$old] then .inbounds[$new]=.inbounds[$old] | del(.inbounds[$old]) else . end' "$META_FILE" >"$meta_tmp"
  if apply_candidate_with_meta "$tmp" "$meta_tmp"; then info "入站已重命名：${old} -> ${new}"; fi
  rm -f "$tmp" "$meta_tmp"
}

delete_inbound() {
  ensure_dependencies inbound-delete; ensure_config
  local tag=${1-} yes=${2:-0} tmp meta_tmp
  [[ -n $tag ]] || select_inbound tag || return
  inbound_exists "$tag" || die "找不到入站：$tag"
  [[ $yes == 1 ]] || confirm "删除入站 ${tag}？" N || return
  tmp=$(temp_file); meta_tmp=$(temp_file); init_meta
  jq --arg tag "$tag" '
    .inbounds |= map(select(.tag!=$tag)) |
    .route.rules = [(.route.rules // [])[]? |
      if ((.inbound // null)|type)=="array" and ((.inbound // [])|index($tag))!=null then
        .inbound |= map(select(.!=$tag)) | select((.inbound|length)>0)
      elif (.inbound // null)==$tag then empty
      else . end]' "$CONFIG_FILE" >"$tmp"
  jq --arg tag "$tag" 'del(.inbounds[$tag])' "$META_FILE" >"$meta_tmp"
  if apply_candidate_with_meta "$tmp" "$meta_tmp"; then info "已删除入站 ${tag}。"; fi
  rm -f "$tmp" "$meta_tmp"
}

enable_bbr() {
  ensure_dependencies bbr
  command_exists sysctl || die "缺少 sysctl。"
  local config=/etc/sysctl.d/99-sbctl-bbr.conf qdisc_ok=0 available
  [[ -w /proc/sys/net/ipv4/tcp_congestion_control ]] || { warn "当前容器/内核不允许修改拥塞控制参数。"; return 0; }
  command_exists modprobe && run_bounded 5 modprobe tcp_bbr >/dev/null 2>&1 || true
  available=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)
  grep -qw bbr <<<"$available" || { warn "当前内核未提供 BBR。"; return 0; }
  if [[ -e /proc/sys/net/core/default_qdisc ]] && run_bounded 5 sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then qdisc_ok=1; fi
  if ! run_bounded 5 sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
    warn "无法启用 BBR；可能处于受限 NAT/LXC/OpenVZ 容器。"
    return 0
  fi
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
    [[ ! -f $config ]] || rm -f "$config"
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
  [[ ! -e /proc/sys/net/core/default_qdisc ]] || run_bounded 5 sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1 || true
  rm -f "$config"
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
    [[ -z $fallback ]] || run_bounded 5 sysctl -w net.ipv4.tcp_congestion_control="$fallback" >/dev/null 2>&1 || true
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
  for path in "$CERTBOT_HOOK_DIR"/sbctl-*; do [[ ! -e $path ]] || { printf '  ✗ 残留: %s\n' "$path"; ((count+=1)); }; done
  pgrep -x sing-box >/dev/null 2>&1 && { printf '  ✗ 残留: sing-box 进程仍在运行\n'; ((count+=1)); }
  printf -v "$__count_var" '%s' "$count"
}

system_diagnostics() {
  ensure_dependencies diagnose
  local v4="" v6="" virt=unknown certs=0 auto=0 account_count=0 unit="" hardening=不适用
  command_exists systemd-detect-virt && virt=$(systemd-detect-virt 2>/dev/null || printf none)
  v4=$(detect_public_ipv4 || true); v6=$(detect_public_ipv6 || true)
  init_meta
  certs=$(managed_certificate_count 2>/dev/null || printf 0)
  auto=$(meta_cert_auto_renew_certs 2>/dev/null | awk 'NF{n++} END{print n+0}')
  account_count=$(certbot_account_ids 2>/dev/null | awk 'NF{n++} END{print n+0}')
  case $(init_system) in
    systemd)
      unit="${SYSTEMD_UNIT_DIR}/${SERVICE_NAME}.service"
      if [[ -r $unit ]] && grep -q '^NoNewPrivileges=true$' "$unit" && grep -q '^ProtectSystem=strict$' "$unit"; then hardening=已启用; else hardening=缺失; fi
      ;;
    openrc) unit="${OPENRC_INIT_DIR}/${SERVICE_NAME}"; [[ -r $unit ]] && hardening=supervise-daemon || hardening=缺失;;
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
    validate_candidate "$CONFIG_FILE" && printf '配置检查: 通过\n' || printf '配置检查: 失败\n'
  fi
}
