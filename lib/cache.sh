# shellcheck shell=bash
# Session-level cache for values that don't change during sbctl's lifetime.
# Uses files under /tmp (not global variables) so cache survives $(...) subshells.
# Cache directory is cleaned up on shell exit — no persistent files.

_SBC_CACHE_DIR="${TMPDIR:-/tmp}/sbctl-cache-$$"
mkdir -p "$_SBC_CACHE_DIR" 2>/dev/null || true
# shellcheck disable=SC2064
trap "rm -rf $_SBC_CACHE_DIR" EXIT

_sbc_cached() {
  local key=$1
  [[ -f $_SBC_CACHE_DIR/$key ]] && cat "$_SBC_CACHE_DIR/$key" 2>/dev/null
}

_sbc_cache() {
  local key=$1 value=$2
  printf '%s' "$value" > "$_SBC_CACHE_DIR/$key" 2>/dev/null || true
}

sbc_invalidate_install_cache() {
  rm -f "$_SBC_CACHE_DIR/_sbc_sing_box_bin" "$_SBC_CACHE_DIR/_sbc_sing_box_version" 2>/dev/null || true
}

sbc_cache_flush() {
  rm -rf "$_SBC_CACHE_DIR" 2>/dev/null || true
  mkdir -p "$_SBC_CACHE_DIR" 2>/dev/null || true
}

# Cached init_system — runs once per session
init_system() {
  local result
  result=$(_sbc_cached _sbc_init_system) && { printf '%s' "$result"; return; }
  if command_exists systemctl && [[ -d /run/systemd/system || ${SBCTL_TESTING:-0} == 1 ]]; then result=systemd
  elif command_exists rc-service; then result=openrc
  else result=unknown; fi
  _sbc_cache _sbc_init_system "$result"
  printf '%s' "$result"
}

# Cached pkg_manager — runs once per session
pkg_manager() {
  local result
  result=$(_sbc_cached _sbc_pkg_manager) && { printf '%s' "$result"; return 0; }
  if command_exists apk; then result=apk
  elif command_exists apt-get; then result=apt
  elif command_exists dnf; then result=dnf
  elif command_exists yum; then result=yum
  elif command_exists pacman; then result=pacman
  elif command_exists zypper; then result=zypper
  else return 1; fi
  _sbc_cache _sbc_pkg_manager "$result"
  printf '%s' "$result"
}

# Cached sing-box binary path
refresh_binary_path() {
  if [[ -n ${SBCTL_SING_BOX_BIN:-} ]]; then
    SING_BOX_BIN=$SBCTL_SING_BOX_BIN
    return
  fi
  local cached
  cached=$(_sbc_cached _sbc_sing_box_bin) && { SING_BOX_BIN=$cached; return; }
  SING_BOX_BIN=$(command -v sing-box 2>/dev/null || printf '%s' "$SING_BOX_BIN")
  _sbc_cache _sbc_sing_box_bin "$SING_BOX_BIN"
}

# Cached sing-box version — survives $(...) calls
sing_box_version() {
  local version
  version=$(_sbc_cached _sbc_sing_box_version) && { printf '%s' "$version"; return; }
  refresh_binary_path
  if [[ -x $SING_BOX_BIN ]]; then
    version=$("$SING_BOX_BIN" version 2>/dev/null | sed -nE '1s/^sing-box version ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')
  fi
  _sbc_cache _sbc_sing_box_version "${version:-}"
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

# Combined service state summaries — single systemctl call for all states
_service_summary_all() {
  # Output: "running_state startup_state version"
  if [[ ${SBCTL_TESTING:-0} == 1 ]]; then
    printf '未安装 未安装 %s' "$(sing_box_version_summary)"
    return
  fi
  local states load active unitfile
  states=$(_service_states)
  load=$(echo "$states" | awk '{print $1}')
  active=$(echo "$states" | awk '{print $2}')
  unitfile=$(echo "$states" | awk '{print $3}')

  local service_str startup_str
  if [[ $load == not-found ]]; then service_str=未安装; elif [[ $active == active ]]; then service_str=运行中; else service_str=已停止; fi
  if [[ $unitfile == enabled ]]; then startup_str=已开启; else startup_str=已关闭; fi
  printf '%s %s %s' "$service_str" "$startup_str" "$(sing_box_version_summary)"
}

service_state_summary() { _service_summary_all | awk '{print $1}'; }
startup_state_summary() { _service_summary_all | awk '{print $2}'; }

sing_box_version_summary() {
  local v
  v=$(sing_box_version)
  if [[ -n $v ]]; then printf '%s' "$v"; else printf '未安装'; fi
}

node_summary() {
  local service_str count=0 version_str
  if [[ ${SBCTL_TESTING:-0} != 1 ]]; then
    local states load active
    states=$(_service_states)
    load=$(echo "$states" | awk '{print $1}')
    active=$(echo "$states" | awk '{print $2}')
    if [[ $load == not-found ]]; then service_str=未安装
    elif [[ $active == active ]]; then service_str=运行中
    else service_str=已停止; fi
  else
    service_str=未安装
  fi
  [[ -f $CONFIG_FILE ]] && count=$(jq '.inbounds|length' "$CONFIG_FILE" 2>/dev/null || printf 0)
  version_str=$(sing_box_version_summary)
  printf '服务: %s  |  入站: %s  |  sing-box: %s\n' "$service_str" "$count" "${version_str:-已安装}"
}
