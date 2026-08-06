# shellcheck shell=bash
# Cloudflare DNS credential management.
# No function overrides — certificate lifecycle lives in certops.sh.

CLOUDFLARE_INI="${SBCTL_CLOUDFLARE_INI:-${CERTBOT_CONFIG_DIR}/cloudflare.ini}"

cloudflare_plugin_available() {
  [[ -x $CERTBOT_VENV/bin/python ]] && "$CERTBOT_VENV/bin/python" -c 'import certbot_dns_cloudflare' >/dev/null 2>&1
}

ensure_cloudflare_certbot_plugin() {
  cloudflare_plugin_available && return 0
  [[ -x $CERTBOT_VENV/bin/pip ]] || { warn "Certbot venv 缺少 pip，无法安装 Cloudflare DNS 插件。"; return 1; }
  info "正在安装 Certbot Cloudflare DNS 插件。"
  _cert_run_bounded 180 "$CERTBOT_VENV/bin/pip" install --disable-pip-version-check --timeout 20 --retries 2 \
    --upgrade certbot-dns-cloudflare >/dev/null || { warn "certbot-dns-cloudflare 安装失败。"; return 1; }
  cloudflare_plugin_available || { warn "Cloudflare DNS 插件安装后仍不可用。"; return 1; }
}

load_cloudflare_credentials() {
  [[ -f $CLOUDFLARE_INI && -r $CLOUDFLARE_INI ]] || return 1
  grep -Eq '^[[:space:]]*dns_cloudflare_email[[:space:]]*=[[:space:]]*[^[:space:]].*$' "$CLOUDFLARE_INI" || return 1
  grep -Eq '^[[:space:]]*dns_cloudflare_api_key[[:space:]]*=[[:space:]]*[^[:space:]].*$' "$CLOUDFLARE_INI"
}

cloudflare_dependent_certificates() {
  init_meta
  jq -r '.certificates | to_entries[] | select(.value.validation == "dns-cloudflare") | .key' "$META_FILE" 2>/dev/null
}

cloudflare_dependency_count() {
  local deps
  deps=$(cloudflare_dependent_certificates)
  [[ -n $deps ]] && printf '%s\n' "$deps" | grep -c . || printf '0'
}

prompt_cloudflare_api_key() {
  local __var=$1 key=""
  while [[ -z $key ]]; do
    if [[ -t 0 ]]; then
      printf 'Cloudflare Global API Key: '
      read -r -s key || { printf '\n'; return 1; }
      printf '\n'
    else
      read -r key || return 1
    fi
    [[ -n $key ]] || warn "API Key 不能为空。"
  done
  [[ $key != *$'\n'* && $key != *$'\r'* ]] || { warn "API Key 格式无效。"; return 1; }
  printf -v "$__var" '%s' "$key"
}

save_cloudflare_credentials() {
  local email=${1-} api_key=${2-} tmp
  while [[ -z $email ]]; do
    prompt_value email "Cloudflare 邮箱" || return 1
    validate_email_address "$email" || { warn "邮箱格式无效。"; email=""; }
  done
  validate_email_address "$email" || { warn "邮箱格式无效。"; return 1; }
  [[ -n $api_key ]] || prompt_cloudflare_api_key api_key || return 1
  [[ $api_key != *$'\n'* && $api_key != *$'\r'* ]] || { warn "API Key 格式无效。"; return 1; }

  mkdir -p "$(dirname "$CLOUDFLARE_INI")"
  tmp=$(temp_file)
  printf 'dns_cloudflare_email = %s\ndns_cloudflare_api_key = %s\n' "$email" "$api_key" >"$tmp"
  install -m 600 "$tmp" "$CLOUDFLARE_INI"
  rm -f "$tmp"
  meta_resource_register certbotConfigDir "$CERTBOT_CONFIG_DIR"
  meta_resource_register cloudflareCredentials "$CLOUDFLARE_INI"
  info "Cloudflare Global API Key 已保存：${CLOUDFLARE_INI}"
}

delete_cloudflare_credentials() {
  local deps
  load_cloudflare_credentials || { info "尚未配置 Cloudflare Global API Key。"; return 0; }
  deps=$(cloudflare_dependent_certificates)
  if [[ -n $deps ]]; then
    warn "以下证书依赖 Cloudflare 凭据自动续期："
    while IFS= read -r id; do [[ -n $id ]] && printf '  - %s\n' "$id" >&2; done <<<"$deps"
    confirm "删除后这些证书将无法自动续期，仍然删除？" N || { info "已取消。"; return 0; }
  else
    confirm "删除 Cloudflare Global API Key？" N || return 0
  fi
  rm -f "$CLOUDFLARE_INI"
  meta_resource_remove cloudflareCredentials
  info "Cloudflare 凭据已删除。"
}

cloudflare_credentials_menu() {
  local choice email=""
  while true; do
    clear_screen; heading "Cloudflare DNS 凭据"
    if load_cloudflare_credentials; then
      email=$(sed -n 's/^[[:space:]]*dns_cloudflare_email[[:space:]]*=[[:space:]]*//p' "$CLOUDFLARE_INI" | head -1)
      printf 'Cloudflare 邮箱: %s\nGlobal API Key: 已配置\n' "${email:-未知}"
    else
      printf 'Cloudflare 凭据: 未配置\n'
    fi
    printf '依赖自动续期证书: %s\n\n' "$(cloudflare_dependency_count)"
    printf '1) 设置/替换邮箱和 Global API Key\n2) 删除凭据\n0) 返回\n'
    read -r -p "请选择: " choice || { echo; return; }
    case $choice in
      1) run_menu_action save_cloudflare_credentials; pause;;
      2) run_menu_action delete_cloudflare_credentials; pause;;
      0) return;; *) warn "无效选项。"; pause;;
    esac
  done
}
