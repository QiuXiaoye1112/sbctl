# shellcheck shell=bash
# Session-level cache for values that don't change during sbctl's lifetime.
# Uses mktemp-created directory under /tmp — survives $(...) subshells.
# Cleanup is handled by core.sh's unified cleanup_on_exit (single EXIT trap).

_SBC_CACHE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sbctl-cache.XXXXXX") || {
  printf '[错误] 无法创建 sbctl 缓存目录\n' >&2
  _SBC_CACHE_DIR=""
}
if [[ -n $_SBC_CACHE_DIR ]]; then
  chmod 700 "$_SBC_CACHE_DIR" 2>/dev/null || true
fi

_sbc_cached() {
  local key=$1
  [[ -n $_SBC_CACHE_DIR && -f $_SBC_CACHE_DIR/$key ]] && cat "$_SBC_CACHE_DIR/$key" 2>/dev/null
}

_sbc_cache() {
  local key=$1 value=$2
  [[ -n $_SBC_CACHE_DIR ]] || return
  printf '%s' "$value" > "$_SBC_CACHE_DIR/$key" 2>/dev/null || true
}

sbc_invalidate_install_cache() {
  [[ -n $_SBC_CACHE_DIR ]] || return
  rm -f "$_SBC_CACHE_DIR/_sbc_sing_box_bin" "$_SBC_CACHE_DIR/_sbc_sing_box_version" 2>/dev/null || true
}

sbc_cache_flush() {
  [[ -n $_SBC_CACHE_DIR ]] || return
  rm -rf -- "$_SBC_CACHE_DIR" 2>/dev/null || true
  _SBC_CACHE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sbctl-cache.XXXXXX") || _SBC_CACHE_DIR=""
  [[ -z $_SBC_CACHE_DIR ]] || chmod 700 "$_SBC_CACHE_DIR" 2>/dev/null || true
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

# ---- service state: single systemctl show, pure-bash parsing ----

# Fetch all service states. Output: "load active unitfile" (three words).
# systemd: one systemctl show call, parsed with bash parameter expansion.
# openrc:  one rc-service + one rc-update call.
_service_states() {
  case $(init_system) in
    systemd)
      local output load active unitfile
      output=$(systemctl show "$SERVICE_NAME" -p LoadState -p ActiveState -p UnitFileState --no-pager 2>/dev/null) || {
        printf 'not-found inactive disabled'
        return
      }
      # Pure-bash extraction from systemctl show output lines.
      # Format: LoadState=loaded\nActiveState=active\nUnitFileState=enabled\n
      load=${output#*LoadState=}; load=${load%%$'\n'*}
      active=${output#*ActiveState=}; active=${active%%$'\n'*}
      unitfile=${output#*UnitFileState=}; unitfile=${unitfile%%$'\n'*}
      printf '%s %s %s' "${load:-not-found}" "${active:-inactive}" "${unitfile:-disabled}"
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
  read -r load _ <<< "$(_service_states)"
  [[ $load != not-found ]]
}

service_is_active() {
  if [[ ${SBCTL_TESTING:-0} == 1 ]]; then return 1; fi
  local _load active
  read -r _load active _ <<< "$(_service_states)"
  [[ $active == active ]]
}

service_is_enabled() {
  local _load _active unitfile
  read -r _load _active unitfile <<< "$(_service_states)"
  [[ $unitfile == enabled ]]
}

# Single call returns all three summaries as space-separated tokens.
# Callers use `read -r svc boot ver <<< "$(_service_summary_all)"`.
_service_summary_all() {
  if [[ ${SBCTL_TESTING:-0} == 1 ]]; then
    printf '未安装 未安装 %s' "$(sing_box_version_summary)"
    return
  fi
  local load active unitfile svc boot ver
  read -r load active unitfile <<< "$(_service_states)"
  if [[ $load == not-found ]]; then svc=未安装; elif [[ $active == active ]]; then svc=运行中; else svc=已停止; fi
  if [[ $unitfile == enabled ]]; then boot=已开启; else boot=已关闭; fi
  ver=$(sing_box_version_summary)
  printf '%s %s %s' "$svc" "$boot" "$ver"
}

service_state_summary() { local s; read -r s _ <<< "$(_service_summary_all)"; printf '%s' "$s"; }
startup_state_summary() { local _ s; read -r _ s _ <<< "$(_service_summary_all)"; printf '%s' "$s"; }

sing_box_version_summary() {
  local v
  v=$(sing_box_version)
  if [[ -n $v ]]; then printf '%s' "$v"; else printf '未安装'; fi
}

node_summary() {
  local svc count=0 ver
  if [[ ${SBCTL_TESTING:-0} != 1 ]]; then
    local load active
    read -r load active _ <<< "$(_service_states)"
    if [[ $load == not-found ]]; then svc=未安装
    elif [[ $active == active ]]; then svc=运行中
    else svc=已停止; fi
  else
    svc=未安装
  fi
  [[ -f $CONFIG_FILE ]] && count=$(jq '.inbounds|length' "$CONFIG_FILE" 2>/dev/null || printf 0)
  ver=$(sing_box_version_summary)
  printf '服务: %s  |  入站: %s  |  sing-box: %s\n' "$svc" "$count" "${ver:-已安装}"
}
