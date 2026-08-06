# shellcheck shell=bash
# sbctl engine — config lifecycle, service definition, install/update, and state transactions.
# This is the canonical implementation; no module overrides these functions.

# ---- config bootstrap ----
ensure_config() {
  [[ -f $CONFIG_FILE ]] || write_default_config
  jq -e 'type=="object" and (.inbounds|type=="array") and (.outbounds|type=="array")' "$CONFIG_FILE" >/dev/null || die "配置不是有效的 sing-box JSON：$CONFIG_FILE"
  normalize_config_tags
  jq -e '
    all(.inbounds[]?; ((.tag // "")|type)=="string" and ((.tag // "")!="")) and
    all(.outbounds[]?; ((.tag // "")|type)=="string" and ((.tag // "")!=""))
  ' "$CONFIG_FILE" >/dev/null || die "配置中的入站/出站标签仍不完整。"
  init_meta
}

write_default_config() {
  mkdir -p "$CONFIG_DIR" "$CERT_DIR" "$(dirname "$META_FILE")"
  cat >"$CONFIG_FILE" <<'JSON'
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct"
  }
}
JSON
  chmod 600 "$CONFIG_FILE"
  init_meta
}

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

require_sing_box() { refresh_binary_path; sing_box_installed || die "sing-box 尚未安装，请先运行 sbctl install。"; }

require_supported_core() {
  local version
  require_sing_box
  version=$(sing_box_version)
  [[ -n $version ]] || die "无法识别 sing-box 版本。"
  version_ge "$version" 1.12.0 || die "sbctl 需要 sing-box >= 1.12.0（AnyTLS 从 1.12.0 起支持），当前为 ${version}。"
}

validate_candidate() {
  local candidate=$1 output
  jq -e 'type=="object" and (.inbounds|type=="array") and (.outbounds|type=="array")' "$candidate" >/dev/null || { error "JSON 结构检查失败。"; return 1; }
  if sing_box_installed; then
    refresh_binary_path
    if ! output=$("$SING_BOX_BIN" check -c "$candidate" 2>&1); then
      error "sing-box 拒绝了新配置："
      printf '%s\n' "$output" >&2
      return 1
    fi
  fi
}

restart_service_checked() {
  service_exists || return 0
  service_restart || return 1
  sleep 0.2
  service_is_active
}

# Transactional config+meta apply (from state_guard.sh)
apply_candidate_with_meta() {
  local candidate=$1 meta_candidate=${2:-} cfg_rollback meta_rollback old_active=0 had_meta=0 failed=0
  ensure_config
  validate_candidate "$candidate" || return 1
  if [[ -n $meta_candidate ]]; then
    jq -e 'type=="object" and ((.inbounds // {})|type=="object")' "$meta_candidate" >/dev/null \
      || { error "metadata 候选文件无效。"; return 1; }
  fi
  service_is_active && old_active=1
  cfg_rollback=$(temp_file)
  meta_rollback=$(temp_file)
  cp -a "$CONFIG_FILE" "$cfg_rollback"
  if [[ -f $META_FILE ]]; then cp -a "$META_FILE" "$meta_rollback"; had_meta=1; fi
  install -m 600 "$candidate" "$CONFIG_FILE" || failed=1
  if ((failed == 0)) && [[ -n $meta_candidate ]]; then install -m 600 "$meta_candidate" "$META_FILE" || failed=1; fi
  if ((failed == 0 && old_active)) && ! restart_service_checked; then failed=1; fi
  if ((failed)); then
    error "状态应用失败，正在回滚 config/meta。"
    install -m 600 "$cfg_rollback" "$CONFIG_FILE" || true
    if ((had_meta)); then install -m 600 "$meta_rollback" "$META_FILE" || true; else rm -f "$META_FILE"; fi
    if ((old_active)); then service_restart >/dev/null 2>&1 || true; fi
    rm -f "$cfg_rollback" "$meta_rollback"
    return 1
  fi
  rm -f "$cfg_rollback" "$meta_rollback"
  info "配置已应用。"
}

# Simple apply (backward compat)
apply_candidate() { apply_candidate_with_meta "$1"; }

# Meta candidate builder (from state_guard.sh)
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

# Canonical service definition (from system_guard.sh — hardened version)
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
  local version=${1-} installer manager had_config=0
  [[ -f $CONFIG_FILE ]] && had_config=1
  manager=$(pkg_manager)
  if [[ $manager == apk ]]; then
    run_bounded 180 apk add --no-cache --upgrade sing-box || die "sing-box 安装/更新失败或超时。"
  else
    installer=$(temp_file)
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 60 \
      "$OFFICIAL_INSTALLER_URL" -o "$installer" || { rm -f "$installer"; die "sing-box 官方安装器下载失败或超时。"; }
    chmod 700 "$installer"
    if [[ -n $version ]]; then
      TERM=${TERM:-xterm} run_bounded 180 bash "$installer" --version "${version#v}" || { rm -f "$installer"; die "sing-box 安装失败或超时。"; }
    else
      TERM=${TERM:-xterm} run_bounded 180 bash "$installer" || { rm -f "$installer"; die "sing-box 安装失败或超时。"; }
    fi
    rm -f "$installer"
  fi
  # Invalidate caches after install/update
  sbc_invalidate_install_cache
  refresh_binary_path
  sing_box_installed || die "sing-box 安装失败。"
  require_supported_core
  if ((had_config)); then
    ensure_config
  else
    write_default_config
  fi
  create_service_definition
  install_quick_command
  validate_candidate "$CONFIG_FILE"
  service_enable
  if ! service_is_active; then service_start; else service_restart; fi
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

check_config() { ensure_config; require_supported_core; validate_candidate "$CONFIG_FILE" && info "配置检查通过。"; }

edit_config() {
  ensure_dependencies config-edit; ensure_config
  local editor=${EDITOR:-vi} tmp
  tmp=$(temp_file); cp -a "$CONFIG_FILE" "$tmp"
  "$editor" "$tmp"
  if cmp -s "$tmp" "$CONFIG_FILE"; then info "配置未更改。"; else apply_candidate "$tmp"; fi
  rm -f "$tmp"
}
