# shellcheck shell=bash
# Session-level cache for values that don't change during sbctl's lifetime.
# No persistent cache files — purely in-memory, process-lifetime only.
# Uses individual variables (not associative arrays) for bash 3.2+ compatibility.

# Cache variables (namespaced with _SBC_C_)
_SBC_C_init_system=""
_SBC_C_pkg_manager=""
_SBC_C_sing_box_bin=""
_SBC_C_sing_box_version=""

sbc_invalidate_install_cache() {
  _SBC_C_sing_box_bin=""
  _SBC_C_sing_box_version=""
}

sbc_cache_flush() {
  _SBC_C_init_system=""
  _SBC_C_pkg_manager=""
  _SBC_C_sing_box_bin=""
  _SBC_C_sing_box_version=""
}

# Cached init_system — runs once per session
init_system() {
  if [[ -n $_SBC_C_init_system ]]; then printf '%s' "$_SBC_C_init_system"; return; fi
  local result
  if command_exists systemctl && [[ -d /run/systemd/system || ${SBCTL_TESTING:-0} == 1 ]]; then result=systemd
  elif command_exists rc-service; then result=openrc
  else result=unknown; fi
  _SBC_C_init_system=$result
  printf '%s' "$result"
}

# Cached pkg_manager — runs once per session
pkg_manager() {
  if [[ -n $_SBC_C_pkg_manager ]]; then printf '%s' "$_SBC_C_pkg_manager"; return 0; fi
  local result=""
  if command_exists apk; then result=apk
  elif command_exists apt-get; then result=apt
  elif command_exists dnf; then result=dnf
  elif command_exists yum; then result=yum
  elif command_exists pacman; then result=pacman
  elif command_exists zypper; then result=zypper
  else return 1; fi
  _SBC_C_pkg_manager=$result
  printf '%s' "$result"
}

# Cached sing-box binary path
refresh_binary_path() {
  if [[ -n ${SBCTL_SING_BOX_BIN:-} ]]; then
    SING_BOX_BIN=$SBCTL_SING_BOX_BIN
    return
  fi
  if [[ -n $_SBC_C_sing_box_bin ]]; then SING_BOX_BIN=$_SBC_C_sing_box_bin; return; fi
  SING_BOX_BIN=$(command -v sing-box 2>/dev/null || printf '%s' "$SING_BOX_BIN")
  _SBC_C_sing_box_bin=$SING_BOX_BIN
}

# Cached sing-box version
sing_box_version() {
  if [[ -n $_SBC_C_sing_box_version ]]; then printf '%s' "$_SBC_C_sing_box_version"; return; fi
  local version=""
  refresh_binary_path
  if [[ -x $SING_BOX_BIN ]]; then
    version=$("$SING_BOX_BIN" version 2>/dev/null | sed -nE '1s/^sing-box version ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')
  fi
  _SBC_C_sing_box_version=${version:-}
  printf '%s' "${version:-}"
}

sing_box_installed() {
  refresh_binary_path
  [[ -x $SING_BOX_BIN ]] || command_exists sing-box
}

# Fetch all service states in one call — returns "LoadState ActiveState UnitFileState"
_service_states() {
  case $(init_system) in
    systemd)
      systemctl show "$SERVICE_NAME" -p LoadState -p ActiveState -p UnitFileState --no-pager 2>/dev/null \
        | awk -F= '{printf "%s ", $2}'
      ;;
    openrc)
      local active=inactive enabled=disabled
      [[ -x $OPENRC_INIT_DIR/$SERVICE_NAME ]] || { printf 'not-found inactive disabled'; return; }
      rc-service "$SERVICE_NAME" status >/dev/null 2>&1 && active=active || true
      rc-update show default 2>/dev/null | grep -Eq "(^|[[:space:]])${SERVICE_NAME}([[:space:]]|$)" && enabled=enabled || true
      printf 'loaded %s %s' "$active" "$enabled"
      ;;
    *) printf 'not-found inactive disabled';;
  esac
}

service_exists() {
  if [[ ${SBCTL_TESTING:-0} == 1 ]]; then return 1; fi
  local load
  load=$(_service_states | awk '{print $1}')
  [[ $load != not-found ]]
}

service_is_active() {
  if [[ ${SBCTL_TESTING:-0} == 1 ]]; then return 1; fi
  local active
  active=$(_service_states | awk '{print $2}')
  [[ $active == active ]]
}

service_is_enabled() {
  local unitfile
  unitfile=$(_service_states | awk '{print $3}')
  [[ $unitfile == enabled ]]
}

# Combined service state summaries — avoids repeated systemctl calls
service_state_summary() {
  if [[ ${SBCTL_TESTING:-0} == 1 ]]; then printf '未安装'; return; fi
  local states load active
  states=$(_service_states)
  load=$(awk '{print $1}' <<<"$states")
  active=$(awk '{print $2}' <<<"$states")
  if [[ $load == not-found ]]; then printf '未安装'
  elif [[ $active == active ]]; then printf '运行中'
  else printf '已停止'; fi
}

startup_state_summary() {
  local unitfile
  unitfile=$(_service_states | awk '{print $3}')
  if [[ $unitfile == enabled ]]; then printf '已开启'; else printf '已关闭'; fi
}

sing_box_version_summary() {
  local v
  v=$(sing_box_version)
  if [[ -n $v ]]; then printf '%s' "$v"; else printf '未安装'; fi
}

node_summary() {
  local service_loader count=0 version_str
  if [[ ${SBCTL_TESTING:-0} != 1 ]]; then
    local states load active
    states=$(_service_states)
    load=$(awk '{print $1}' <<<"$states")
    active=$(awk '{print $2}' <<<"$states")
    if [[ $load == not-found ]]; then service_loader=未安装
    elif [[ $active == active ]]; then service_loader=运行中
    else service_loader=已停止; fi
  else
    service_loader=未安装
  fi
  [[ -f $CONFIG_FILE ]] && count=$(jq '.inbounds|length' "$CONFIG_FILE" 2>/dev/null || printf 0)
  version_str=$(sing_box_version_summary)
  printf '服务: %s  |  入站: %s  |  sing-box: %s\n' "$service_loader" "$count" "${version_str:-已安装}"
}
