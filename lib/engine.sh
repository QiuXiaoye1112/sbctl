write_default_config() {
  mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$CERT_DIR" "$(dirname "$META_FILE")"
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
ensure_config() {
  [[ -f $CONFIG_FILE ]] || write_default_config
  jq -e 'type=="object" and (.inbounds|type=="array") and (.outbounds|type=="array")' "$CONFIG_FILE" >/dev/null || die "配置不是有效的 sing-box JSON：$CONFIG_FILE"
  init_meta
}

sing_box_installed() { [[ -x $SING_BOX_BIN ]] || command_exists sing-box; }
refresh_binary_path() { SING_BOX_BIN=$(command -v sing-box 2>/dev/null || printf '%s' "$SING_BOX_BIN"); }
require_sing_box() { refresh_binary_path; sing_box_installed || die "sing-box 尚未安装，请先运行 sbctl install。"; }

sing_box_version() {
  refresh_binary_path
  "$SING_BOX_BIN" version 2>/dev/null | sed -nE '1s/^sing-box version ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p'
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

apply_candidate() {
  local candidate=$1 rollback old_active=0
  ensure_config
  validate_candidate "$candidate" || return 1
  service_is_active && old_active=1
  rollback=$(temp_file); cp -a "$CONFIG_FILE" "$rollback"
  install -m 600 "$candidate" "$CONFIG_FILE"
  if ((old_active)) && ! restart_service_checked; then
    error "重启失败，正在回滚配置。"
    install -m 600 "$rollback" "$CONFIG_FILE"
    service_restart >/dev/null 2>&1 || true
    rm -f "$rollback"
    return 1
  fi
  rm -f "$rollback"
  info "配置已应用。"
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

[Install]
WantedBy=multi-user.target
EOF_UNIT
      systemctl daemon-reload
      ;;
    openrc)
      mkdir -p "$OPENRC_INIT_DIR"
      cat >"${OPENRC_INIT_DIR}/$SERVICE_NAME" <<EOF_RC
#!/sbin/openrc-run
name="sing-box"
description="sing-box service managed by sbctl"
command="${SING_BOX_BIN}"
command_args="run -D ${DATA_DIR} -c ${CONFIG_FILE}"
command_background="yes"
pidfile="/run/${SERVICE_NAME}.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
depend() { need net; after firewall; }
EOF_RC
      chmod 755 "${OPENRC_INIT_DIR}/$SERVICE_NAME"
      ;;
    *) die "未检测到 systemd 或 OpenRC。";;
  esac
}

install_quick_command() {
  local source=${SBCTL_ENTRYPOINT:-${BASH_SOURCE[0]:-}} downloaded=""
  mkdir -p "$(dirname "$QUICK_COMMAND")" "$(dirname "$QUICK_SYMLINK")"
  if [[ -z $source || ! -r $source ]] || ! grep -q '^# sbctl - sing-box Linux terminal manager' "$source" 2>/dev/null; then
    downloaded=$(temp_file)
    curl -fsSL --retry 3 "$SCRIPT_DOWNLOAD_URL" -o "$downloaded" || die "sbctl 下载失败。"
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
}

install_or_update_sing_box() {
  ensure_dependencies install
  local version=${1-} installer manager had_config=0
  [[ -f $CONFIG_FILE ]] && had_config=1
  manager=$(pkg_manager)
  if [[ $manager == apk ]]; then
    apk add --no-cache --upgrade sing-box
  else
    installer=$(temp_file)
    curl -fsSL --retry 3 "$OFFICIAL_INSTALLER_URL" -o "$installer"
    chmod 700 "$installer"
    if [[ -n $version ]]; then bash "$installer" --version "${version#v}"; else bash "$installer"; fi
    rm -f "$installer"
  fi
  refresh_binary_path
  sing_box_installed || die "sing-box 安装失败。"
  require_supported_core
  if ((had_config)); then
    ensure_config
  else
    # Some sing-box packages/installers create a demonstration config (commonly
    # a Shadowsocks listener on 8080). A fresh sbctl install must start empty.
    write_default_config
  fi
  create_service_definition
  install_quick_command
  validate_candidate "$CONFIG_FILE"
  service_enable
  if ! service_is_active; then service_start; else service_restart; fi
  info "sing-box 已就绪：$($SING_BOX_BIN version | sed -n '1p')"
}

uninstall_sing_box() {
  ensure_dependencies uninstall
  local purge=${1:-0} manager
  if [[ $purge == 1 ]]; then
    confirm "彻底卸载并删除配置、证书和元数据？" N || return 0
  else
    confirm "卸载 sing-box，保留配置？" N || return 0
  fi
  service_stop >/dev/null 2>&1 || true
  service_disable >/dev/null 2>&1 || true
  manager=$(pkg_manager)
  case $manager in
    apk) apk del sing-box 2>/dev/null || true ;;
    apt) apt-get remove -y sing-box 2>/dev/null || true ;;
    dnf) dnf remove -y sing-box 2>/dev/null || true ;;
    yum) yum remove -y sing-box 2>/dev/null || true ;;
    pacman) pacman -Rns --noconfirm sing-box 2>/dev/null || true ;;
    zypper) zypper --non-interactive remove sing-box 2>/dev/null || true ;;
  esac
  [[ $(init_system) != systemd ]] || { rm -f "${SYSTEMD_UNIT_DIR}/${SERVICE_NAME}.service"; systemctl daemon-reload; }
  [[ $(init_system) != openrc ]] || rm -f "${OPENRC_INIT_DIR}/${SERVICE_NAME}"
  if [[ $purge == 1 ]]; then
    rm -rf "$CONFIG_DIR" "$DATA_DIR"
    rm -f "$META_FILE"
    rmdir "$(dirname "$META_FILE")" 2>/dev/null || true
  fi
  info "卸载完成。"
}
