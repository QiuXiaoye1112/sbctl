# shellcheck shell=bash
# sbctl certificate lifecycle — canonical implementation.
# Includes Let's Encrypt, Cloudflare DNS, manual DNS, and IP certificate flows.

validate_email_address() { [[ ${1:-} == *@*.* && ${1:-} != *" "* ]]; }
validate_certificate_identifier() { [[ ${1:-} =~ ^[A-Za-z0-9_.-]+$ ]]; }

certbot_supports_ip() { [[ -x $CERTBOT_BIN ]] && "$CERTBOT_BIN" --help all 2>/dev/null | grep -q -- '--ip-address'; }

certbot_nginx_available() {
  [[ -x $CERTBOT_VENV/bin/python ]] && "$CERTBOT_VENV/bin/python" -c 'import certbot_nginx' >/dev/null 2>&1
}

install_certbot() { ensure_certbot_environment; }

certbot_account_ids() {
  local file id
  for file in "$CERTBOT_CONFIG_DIR"/accounts/*/*/*/regr.json; do
    [[ -f $file ]] || continue
    id=$(basename "$(dirname "$file")")
    printf '%s\n' "$id"
  done | sort -u
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

detect_port80_owner() {
  local pid pname="" line
  if command_exists ss; then
    line=$(ss -H -ltnp 2>/dev/null | awk '$4 ~ /:80$/ || $4 ~ /\]:80$/ {print; exit}')
    pid=$(sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' <<<"$line" | head -1)
    [[ -z $pid ]] || pname=$(ps -p "$pid" -o comm= 2>/dev/null | tr -d '[:space:]')
    [[ -n $line ]] || { printf free; return; }
  elif command_exists netstat; then
    line=$(netstat -ltnp 2>/dev/null | awk '$4 ~ /:80$/ {print; exit}')
    [[ -n $line ]] || { printf free; return; }
    pname=$(awk '{print $7}' <<<"$line" | sed 's#^[0-9]*/##')
  else
    printf unknown; return
  fi
  case $pname in
    sing-box) printf sing-box;;
    nginx) printf nginx;;
    httpd|apache2) printf apache;;
    "") printf other;;
    *) printf other;;
  esac
}

# ---- cert renewal helpers ----

# Legacy hook writer — creates per-cert deploy hook for Certbot.
# Still available for compatibility; canonical renewal uses setup_certbot_renewal_timer.
write_certbot_hook() {
  local domain=$1 hook
  hook="${CERTBOT_HOOK_DIR}/sbctl-${domain}"
  mkdir -p "$(dirname "$hook")"
  case $(init_system) in
    systemd)
      cat >"$hook" <<EOF_HOOK
#!/usr/bin/env bash
set -e
install -m 600 /etc/letsencrypt/live/${domain}/fullchain.pem ${CERT_DIR}/${domain}.crt
install -m 600 /etc/letsencrypt/live/${domain}/privkey.pem ${CERT_DIR}/${domain}.key
systemctl try-restart ${SERVICE_NAME}.service || true
EOF_HOOK
      ;;
    openrc)
      cat >"$hook" <<EOF_HOOK
#!/usr/bin/env bash
set -e
install -m 600 /etc/letsencrypt/live/${domain}/fullchain.pem ${CERT_DIR}/${domain}.crt
install -m 600 /etc/letsencrypt/live/${domain}/privkey.pem ${CERT_DIR}/${domain}.key
rc-service ${SERVICE_NAME} restart || true
EOF_HOOK
      ;;
  esac
  chmod 700 "$hook"
}

replace_certificate_pair() {
  local source_cert=$1 source_key=$2 cert_target=$3 key_target=$4 __changed_var=${5:-}
  local cert_tmp="${cert_target}.new" key_tmp="${key_target}.new" cert_bak="${cert_target}.bak" key_bak="${key_target}.bak"
  local replace_changed=1 had_cert=0 had_key=0 failed=0
  mkdir -p "$(dirname "$cert_target")"
  install -m 600 "$source_cert" "$cert_tmp" || return 1
  install -m 600 "$source_key" "$key_tmp" || { rm -f "$cert_tmp"; return 1; }
  validate_certificate_pair "$cert_tmp" "$key_tmp" || { rm -f "$cert_tmp" "$key_tmp"; warn "新证书或私钥无效/不匹配/已过期。"; return 1; }
  if [[ -f $cert_target && -f $key_target ]] && cmp -s "$cert_tmp" "$cert_target" && cmp -s "$key_tmp" "$key_target"; then
    replace_changed=0; rm -f "$cert_tmp" "$key_tmp"
    [[ -z $__changed_var ]] || printf -v "$__changed_var" '%s' "$replace_changed"
    return 0
  fi
  [[ ! -f $cert_target ]] || { cp -a "$cert_target" "$cert_bak"; had_cert=1; }
  [[ ! -f $key_target ]] || { cp -a "$key_target" "$key_bak"; had_key=1; }
  mv -f "$cert_tmp" "$cert_target" || failed=1
  mv -f "$key_tmp" "$key_target" || failed=1
  if ((failed)); then
    ((had_cert)) && mv -f "$cert_bak" "$cert_target" || rm -f "$cert_target"
    ((had_key)) && mv -f "$key_bak" "$key_target" || rm -f "$key_target"
    rm -f "$cert_tmp" "$key_tmp" "$cert_bak" "$key_bak"
    warn "证书替换失败，已恢复原状态。"; return 1
  fi
  rm -f "$cert_bak" "$key_bak"
  [[ -z $__changed_var ]] || printf -v "$__changed_var" '%s' "$replace_changed"
}

restart_sing_box_if_certificate_changed() {
  [[ ${1:-0} == 1 ]] || return 0
  service_is_active || return 0
  if restart_service_checked; then info "sing-box 已重启以加载新证书。"; else warn "证书已更新，但 sing-box 重启失败。"; return 1; fi
}

sync_managed_certificate() {
  local identifier=$1 cert_name=${2:-$1} __changed_var=${3:-}
  local source_cert="${CERTBOT_CONFIG_DIR}/live/${cert_name}/fullchain.pem"
  local source_key="${CERTBOT_CONFIG_DIR}/live/${cert_name}/privkey.pem"
  [[ -r $source_cert ]] || { warn "无法读取 Certbot 证书：$source_cert"; return 1; }
  [[ -r $source_key ]] || { warn "无法读取 Certbot 私钥：$source_key"; return 1; }
  replace_certificate_pair "$source_cert" "$source_key" "$CERT_DIR/${identifier}.crt" "$CERT_DIR/${identifier}.key" "$__changed_var"
}

certificate_identifier_for_subject() {
  local subject=$1
  if validate_ip_literal "$subject"; then
    if [[ $subject == *:* ]]; then printf 'ip6-%s' "$(printf '%s' "$subject" | openssl dgst -sha256 -r | awk '{print substr($1,1,8)}')"
    else printf 'ip4-%s' "$(printf '%s' "$subject" | openssl dgst -sha256 -r | awk '{print substr($1,1,8)}')"; fi
  else printf '%s' "$subject"; fi
}

setup_certbot_renewal_timer() {
  [[ -x $QUICK_COMMAND ]] || install_quick_command
  case $(init_system) in
    systemd)
      cat >"${SYSTEMD_UNIT_DIR}/sbctl-certbot-renew.service" <<EOF_SERVICE
[Unit]
Description=Renew certificates managed by sbctl

[Service]
Type=oneshot
ExecStart=${QUICK_COMMAND} cert renew-auto
EOF_SERVICE
      cat >"${SYSTEMD_UNIT_DIR}/sbctl-certbot-renew.timer" <<'EOF_TIMER'
[Unit]
Description=Renew certificates managed by sbctl

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF_TIMER
      systemctl daemon-reload
      systemctl enable --now sbctl-certbot-renew.timer >/dev/null
      meta_resource_register renewService "${SYSTEMD_UNIT_DIR}/sbctl-certbot-renew.service"
      meta_resource_register renewTimer "${SYSTEMD_UNIT_DIR}/sbctl-certbot-renew.timer"
      ;;
    openrc)
      mkdir -p /etc/periodic/daily
      cat >/etc/periodic/daily/sbctl-certbot-renew <<EOF_CRON
#!/bin/sh
${QUICK_COMMAND} cert renew-auto
EOF_CRON
      chmod 755 /etc/periodic/daily/sbctl-certbot-renew
      meta_resource_register renewPeriodic /etc/periodic/daily/sbctl-certbot-renew
      ;;
    *) die "无法配置证书自动续期：未检测到 systemd/OpenRC。";;
  esac
}

# ---- cert issuance sub-flows ----
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
    apache) warn "80 端口被 Apache 占用；请改用 DNS 手动验证。"; return 1;;
    *) warn "80 端口被其他程序占用或无法识别；请改用 DNS 手动验证。"; return 1;;
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
        ((was_active)) && { service_start || true; CERT_STOPPED_SERVICE=0; }; return 1
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

# ---- canonical issue_certificate (includes Cloudflare DNS path) ----
issue_certificate() {
  ensure_dependencies cert-issue
  ensure_certbot_environment
  local subject=${1-} email=${2-} mode=domain verify_method="" identifier cert_name validation auto_renew=false force=0 changed=0
  if [[ -z $subject ]]; then
    local default_subject=""
    default_subject=$(detect_public_ipv4 || true); [[ -n $default_subject ]] || default_subject=$(detect_public_ipv6 || true)
    while true; do
      prompt_value subject "证书域名/IP" "$default_subject" || return 1
      validate_host "$subject" && break
      warn "证书域名/IP 无效。"
    done
  fi
  if validate_ip_literal "$subject"; then mode=ip; elif ! validate_domain "$subject"; then die "证书域名/IP 无效。"; fi
  identifier=$(certificate_identifier_for_subject "$subject"); cert_name=$identifier
  [[ $mode == domain ]] && cert_name=$subject

  if [[ $mode == domain ]]; then
    choose verify_method "选择验证方式" \
      "Cloudflare DNS（自动验证/自动续期）" \
      "HTTP（自动续期，需要 80 端口）" \
      "DNS（手动添加 TXT，不自动续期）" || return 1
    case $verify_method in
      1) verify_method=dns-cloudflare;;
      2) verify_method=http;;
      3) verify_method=dns-manual;;
    esac
    if [[ $verify_method == dns-cloudflare ]] && ! load_cloudflare_credentials; then
      info "首次使用 Cloudflare DNS 自动验证，需要配置 Cloudflare 邮箱和 Global API Key。"
      save_cloudflare_credentials || return 1
    fi
  fi

  while [[ -z $email ]]; do
    prompt_value email "Let's Encrypt 联系邮箱" || return 1
    validate_email_address "$email" || { warn "邮箱格式无效。"; email=""; }
  done
  validate_email_address "$email" || die "邮箱格式无效。"

  if meta_cert_exists "$identifier" || [[ -f $CERT_DIR/${identifier}.crt || -f $CERT_DIR/${identifier}.key ]]; then
    local users
    users=$(certificate_inbound_users "$identifier" 2>/dev/null || true)
    [[ -z $users ]] || warn "证书正在被入站使用：$(paste -sd ',' <<<"$users")"
    confirm "证书 ${identifier} 已存在，是否强制重新签发？" N || { info "已取消。"; return 0; }
    force=1
  fi

  if [[ $mode == ip ]]; then
    validation=http-standalone; auto_renew=true
    _issue_ip_certificate "$subject" "$email" "$force" || { warn "证书签发失败。"; return 1; }
  elif [[ $verify_method == dns-cloudflare ]]; then
    validation=dns-cloudflare; auto_renew=true
    _issue_domain_cloudflare "$subject" "$email" "$force" || { warn "Cloudflare DNS 证书签发失败。"; return 1; }
  elif [[ $verify_method == dns-manual ]]; then
    validation=dns-manual; auto_renew=false
    _issue_domain_manual_dns "$subject" "$email" "$force" || { warn "证书签发失败。"; return 1; }
  else
    _issue_domain_http "$subject" "$email" "$force" validation || { warn "证书签发失败。"; return 1; }
    auto_renew=true
  fi

  sync_managed_certificate "$identifier" "$cert_name" changed || { warn "证书已签发，但同步到 sbctl 托管目录失败。"; return 1; }
  meta_cert_set "$identifier" "$subject" "$cert_name" letsencrypt "$validation" "$auto_renew"
  [[ $auto_renew == true ]] && setup_certbot_renewal_timer
  restart_sing_box_if_certificate_changed "$changed" || return 1
  info "证书已签发并托管：${identifier}"
}

import_certificate() {
  ensure_dependencies cert-import
  local identifier=${1-} cert=${2-} key=${3-} subject changed=0
  [[ -n $identifier ]] || prompt_value identifier "证书标识/域名" || return 1
  validate_certificate_identifier "$identifier" || die "证书标识无效。"
  [[ -n $cert ]] || prompt_value cert "证书文件路径" || return 1
  [[ -n $key ]] || prompt_value key "私钥文件路径" || return 1
  validate_certificate_pair "$cert" "$key" || { warn "证书/私钥无效、不匹配或已过期。"; return 1; }
  subject=$(certificate_server_names "$cert" | head -1 || true); [[ -n $subject ]] || subject=$identifier
  replace_certificate_pair "$cert" "$key" "$CERT_DIR/${identifier}.crt" "$CERT_DIR/${identifier}.key" changed || return 1
  meta_cert_set "$identifier" "$subject" "$identifier" imported imported false
  restart_sing_box_if_certificate_changed "$changed" || return 1
  info "证书已导入：${identifier}"
}

list_certificates() {
  init_meta
  local id cert found=0 subject source validation auto_renew cert_name
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    found=1; cert="$CERT_DIR/${id}.crt"
    subject=$(meta_cert_get_field "$id" subject); source=$(meta_cert_get_field "$id" source)
    validation=$(meta_cert_get_field "$id" validation); auto_renew=$(meta_cert_get_field "$id" autoRenew)
    cert_name=$(meta_cert_get_field "$id" certName)
    printf '标识: %s\n' "$id"
    [[ -z $subject || $subject == "$id" ]] || printf '域名/IP: %s\n' "$subject"
    [[ -z $cert_name || $cert_name == "$id" ]] || printf 'Certbot 名称: %s\n' "$cert_name"
    case $source in letsencrypt) printf "来源: Let's Encrypt\n";; imported) printf '来源: 手动导入\n';; legacy) printf '来源: 旧版本迁移\n';; *) printf '来源: %s\n' "${source:-未知}";; esac
    printf '验证: %s\n自动续期: %s\n' "${validation:-未知}" "$([[ $auto_renew == true ]] && printf 是 || printf 否)"
    [[ $source != legacy ]] || printf '状态: 旧版证书仅登记副本；建议重新签发以接入新续期机制\n'
    if [[ -r $cert ]]; then openssl x509 -in "$cert" -noout -subject -issuer -dates 2>/dev/null | sed 's/^/  /'; else printf '  [证书文件缺失]\n'; fi
    printf '\n'
  done < <(meta_cert_list)
  ((found)) || info "没有托管证书。"
}

certificate_inbound_users() {
  local identifier=$1 cert="$CERT_DIR/${identifier}.crt" key="$CERT_DIR/${identifier}.key"
  [[ -r $CONFIG_FILE ]] || return 0
  jq -r --arg cert "$cert" --arg key "$key" '
    .inbounds[]? | select(.tls.enabled==true) |
    select((.tls.certificate_path // "")==$cert or (.tls.key_path // "")==$key) | .tag
  ' "$CONFIG_FILE"
}

# Disable renewal timer if no certs need it
_disable_renewal_job_if_unused() {
  local remaining
  remaining=$(meta_cert_auto_renew_certs | head -1 || true)
  [[ -z $remaining ]] || return 0
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

delete_certificate() {
  ensure_dependencies cert-delete
  local identifier=${1-} assume_yes=${2:-0} users source cert_name subject tag rc=0
  [[ -n $identifier ]] || select_managed_certificate identifier 1 || return 0
  validate_certificate_identifier "$identifier" || die "证书标识无效。"
  meta_cert_exists "$identifier" || { warn "该证书不在 sbctl 托管列表中。"; return 1; }
  users=$(certificate_inbound_users "$identifier")
  if [[ -n $users ]]; then
    warn "证书正在被以下 TLS 入站使用，不能删除："
    while IFS= read -r tag; do [[ -n $tag ]] && printf '  - %s\n' "$tag" >&2; done <<<"$users"
    return 0
  fi
  [[ $assume_yes == 1 ]] || confirm "删除托管证书 ${identifier}？" N || return 0
  source=$(meta_cert_get_field "$identifier" source); cert_name=$(meta_cert_get_field "$identifier" certName); subject=$(meta_cert_get_field "$identifier" subject)
  if [[ $source == letsencrypt && -n $cert_name && -f $CERTBOT_CONFIG_DIR/renewal/${cert_name}.conf ]]; then
    if [[ -x $CERTBOT_BIN ]]; then
      certbot_cmd delete --cert-name "$cert_name" --non-interactive || { warn "Certbot lineage 删除失败，托管副本未删除。"; return 1; }
    else
      warn "Certbot 环境缺失，无法安全删除 Let's Encrypt lineage。"; return 1;
    fi
  fi
  rm -f "$CERT_DIR/${identifier}.crt" "$CERT_DIR/${identifier}.key"
  rm -f "$CERTBOT_HOOK_DIR/sbctl-${identifier}" "$CERTBOT_HOOK_DIR/sbctl-${subject}"
  meta_cert_delete "$identifier"
  _disable_renewal_job_if_unused
  info "托管证书已删除：${identifier}"
}

# ---- canonical renewal (includes Cloudflare DNS path) ----
renew_one_certificate() {
  local identifier=$1 __result_var=${2:-} cert_name validation owner before_serial="" after_serial="" changed=0 was_active=0 renewal_result_internal=failed
  meta_cert_exists "$identifier" || { warn "证书不在托管列表：$identifier"; [[ -z $__result_var ]] || printf -v "$__result_var" '%s' failed; return 1; }
  cert_name=$(meta_cert_get_field "$identifier" certName); validation=$(meta_cert_get_field "$identifier" validation)

  # Cloudflare DNS path
  if [[ $validation == dns-cloudflare ]]; then
    if ! load_cloudflare_credentials; then
      warn "${identifier}: Cloudflare 邮箱 / Global API Key 缺失，自动续期阻塞。"
      [[ -z $__result_var ]] || printf -v "$__result_var" '%s' blocked
      return 0
    fi
    if ! ensure_cloudflare_certbot_plugin; then
      warn "${identifier}: Cloudflare DNS 插件不可用。"
      [[ -z $__result_var ]] || printf -v "$__result_var" '%s' failed
      return 1
    fi
    [[ -r $CERTBOT_CONFIG_DIR/live/${cert_name}/fullchain.pem ]] && before_serial=$(openssl x509 -in "$CERTBOT_CONFIG_DIR/live/${cert_name}/fullchain.pem" -noout -serial 2>/dev/null || true)
    if ! certbot_cmd renew --cert-name "$cert_name" --quiet; then
      warn "证书续期失败：${identifier}"
      [[ -z $__result_var ]] || printf -v "$__result_var" '%s' failed
      return 1
    fi
    [[ -r $CERTBOT_CONFIG_DIR/live/${cert_name}/fullchain.pem ]] && after_serial=$(openssl x509 -in "$CERTBOT_CONFIG_DIR/live/${cert_name}/fullchain.pem" -noout -serial 2>/dev/null || true)
    sync_managed_certificate "$identifier" "$cert_name" changed || { [[ -z $__result_var ]] || printf -v "$__result_var" '%s' failed; return 1; }
    restart_sing_box_if_certificate_changed "$changed" || { [[ -z $__result_var ]] || printf -v "$__result_var" '%s' failed; return 1; }
    if [[ -n $before_serial && -n $after_serial && $before_serial != "$after_serial" ]]; then renewal_result_internal=renewed; else renewal_result_internal=unchanged; fi
    [[ -z $__result_var ]] || printf -v "$__result_var" '%s' "$renewal_result_internal"
    return 0
  fi

  # Non-Cloudflare paths
  case $validation in
    dns-manual|legacy|imported)
      warn "${identifier}: 当前类型不能自动续期，请重新签发/导入。"
      [[ -z $__result_var ]] || printf -v "$__result_var" '%s' blocked
      return 0
      ;;
    http-standalone)
      owner=$(detect_port80_owner)
      case $owner in free) :;; sing-box) service_is_active && { was_active=1; service_stop; CERT_STOPPED_SERVICE=1; };; *) warn "${identifier}: 80 端口被占用，自动续期阻塞。"; [[ -z $__result_var ]] || printf -v "$__result_var" '%s' blocked; return 0;; esac
      ;;
    nginx) :;;
    *) warn "${identifier}: 未知验证方式 ${validation}。"; [[ -z $__result_var ]] || printf -v "$__result_var" '%s' failed; return 1;;
  esac
  [[ -x $CERTBOT_BIN ]] || { warn "Certbot 环境缺失，请重新执行证书签发。"; [[ -z $__result_var ]] || printf -v "$__result_var" '%s' failed; return 1; }
  [[ -r $CERTBOT_CONFIG_DIR/live/${cert_name}/fullchain.pem ]] && before_serial=$(openssl x509 -in "$CERTBOT_CONFIG_DIR/live/${cert_name}/fullchain.pem" -noout -serial 2>/dev/null || true)
  if ! certbot_cmd renew --cert-name "$cert_name" --quiet; then
    ((was_active)) && { service_start || true; CERT_STOPPED_SERVICE=0; }
    warn "证书续期失败：${identifier}"; [[ -z $__result_var ]] || printf -v "$__result_var" '%s' failed; return 1
  fi
  ((was_active)) && { service_start; CERT_STOPPED_SERVICE=0; }
  [[ -r $CERTBOT_CONFIG_DIR/live/${cert_name}/fullchain.pem ]] && after_serial=$(openssl x509 -in "$CERTBOT_CONFIG_DIR/live/${cert_name}/fullchain.pem" -noout -serial 2>/dev/null || true)
  sync_managed_certificate "$identifier" "$cert_name" changed || { [[ -z $__result_var ]] || printf -v "$__result_var" '%s' failed; return 1; }
  restart_sing_box_if_certificate_changed "$changed" || { [[ -z $__result_var ]] || printf -v "$__result_var" '%s' failed; return 1; }
  if [[ -n $before_serial && -n $after_serial && $before_serial != "$after_serial" ]]; then renewal_result_internal=renewed; else renewal_result_internal=unchanged; fi
  [[ -z $__result_var ]] || printf -v "$__result_var" '%s' "$renewal_result_internal"
}

renew_managed_certificates() {
  ensure_dependencies cert-renew
  local id result renewed=0 unchanged=0 blocked=0 failed=0
  while IFS= read -r id; do
    [[ -n $id ]] || continue; result=""
    renew_one_certificate "$id" result || result=${result:-failed}
    case $result in renewed) ((renewed+=1));; unchanged) ((unchanged+=1));; blocked) ((blocked+=1));; *) ((failed+=1));; esac
  done < <(meta_cert_auto_renew_certs)
  printf '续期检查：已续期 %d，无需续期 %d，阻塞 %d，失败 %d\n' "$renewed" "$unchanged" "$blocked" "$failed"
  ((failed == 0))
}

renew_certificate_command() {
  local identifier=${1-} result=""
  ensure_dependencies cert-renew
  [[ -n $identifier ]] || die "请提供证书标识。"
  renew_one_certificate "$identifier" result || return 1
  case $result in renewed) info "${identifier}: 已续期。";; unchanged) info "${identifier}: 无需续期。";; blocked) warn "${identifier}: 自动续期被阻塞。";; esac
}
