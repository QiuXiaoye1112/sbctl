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
  [[ -x $SING_BOX_BIN ]] && return 0
  [[ -z ${SBCTL_SING_BOX_BIN:-} ]] && command_exists sing-box
}

# ---- service state: single systemctl show, pure-bash parsing ----

# Fetch all service states. Output: "load active unitfile" (three words).
# systemd: one systemctl show call, parsed with bash parameter expansion.
# openrc:  one rc-service + one rc-update call.
_service_states() {
  case $(init_system) in
    systemd)
      local load=not-found active=inactive unitfile=disabled line
      while IFS= read -r line; do
        case $line in
          LoadState=*)   load=${line#LoadState=} ;;
          ActiveState=*) active=${line#ActiveState=} ;;
          UnitFileState=*) unitfile=${line#UnitFileState=} ;;
        esac
      done < <(systemctl show "$SERVICE_NAME" -p LoadState -p ActiveState -p UnitFileState --no-pager 2>/dev/null || true)
      printf '%s\t%s\t%s' "$load" "$active" "$unitfile"
      ;;
    openrc)
      local active=inactive enabled=disabled
      [[ -x $OPENRC_INIT_DIR/$SERVICE_NAME ]] || { printf 'not-found\tinactive\tdisabled'; return; }
      rc-service "$SERVICE_NAME" status >/dev/null 2>&1 && active=active || true
      rc-update show default 2>/dev/null | grep -Eq "(^|[[:space:]])${SERVICE_NAME}([[:space:]]|$)" && enabled=enabled || true
      printf 'loaded\t%s\t%s' "$active" "$enabled"
      ;;
    *) printf 'not-found\tinactive\tdisabled';;
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

# Single call returns all three summaries as tab-separated tokens (IFS=$'\n\t').
# Callers use `read -r svc boot ver <<< "$(_service_summary_all)"`.
_service_summary_all() {
  if [[ ${SBCTL_TESTING:-0} == 1 ]]; then
    printf '未安装\t未安装\t%s' "$(sing_box_version_summary)"
    return
  fi
  local load active unitfile svc boot ver
  read -r load active unitfile <<< "$(_service_states)"
  if [[ $load == not-found ]]; then svc=未安装; elif [[ $active == active ]]; then svc=运行中; else svc=已停止; fi
  if [[ $unitfile == enabled ]]; then boot=已开启; else boot=已关闭; fi
  ver=$(sing_box_version_summary)
  printf '%s\t%s\t%s' "$svc" "$boot" "$ver"
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

# APT uses a foreground timeout when available so package hooks cannot suspend
# sbctl through SIGTTIN/SIGTTOU on a controlling terminal.
_apt_run_bounded() {
  local seconds=$1; shift
  if command_exists timeout; then
    if timeout --help 2>&1 | grep -F -- '--foreground' >/dev/null; then
      timeout --foreground "$seconds" "$@"
    else
      timeout "$seconds" "$@"
    fi
  else
    "$@"
  fi
}

platform_apt_get() {
  local total_timeout=${SBCTL_APT_TIMEOUT:-180}
  local apt_options=(
    -o Acquire::Retries=2
    -o Acquire::http::Timeout=15
    -o Acquire::https::Timeout=15
    -o Dpkg::Use-Pty=0
  )
  apt_ipv4_available && apt_options+=(-o Acquire::ForceIPv4=true)
  _apt_run_bounded "$total_timeout" env \
    DEBIAN_FRONTEND=noninteractive \
    APT_LISTCHANGES_FRONTEND=none \
    apt-get "${apt_options[@]}" "$@"
}


# ---- platform operations ----
# ---- service actions (uncached — these have side effects) ----
service_start() {
  case $(init_system) in systemd) systemctl start "$SERVICE_NAME";; openrc) rc-service "$SERVICE_NAME" start;; *) return 1;; esac
}
service_stop() {
  case $(init_system) in systemd) systemctl stop "$SERVICE_NAME";; openrc) rc-service "$SERVICE_NAME" stop;; *) return 1;; esac
}
service_restart() {
  case $(init_system) in systemd) systemctl restart "$SERVICE_NAME";; openrc) rc-service "$SERVICE_NAME" restart;; *) return 1;; esac
}
service_enable() {
  case $(init_system) in
    systemd) systemctl enable "$SERVICE_NAME" >/dev/null ;;
    openrc) rc-update add "$SERVICE_NAME" default >/dev/null ;;
    *) return 1;;
  esac
}
service_disable() {
  case $(init_system) in
    systemd) systemctl disable "$SERVICE_NAME" >/dev/null ;;
    openrc) rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true ;;
    *) return 1;;
  esac
}
service_logs() {
  local lines=${1:-100}
  case $(init_system) in
    systemd) journalctl -u "$SERVICE_NAME" -n "$lines" --no-pager ;;
    openrc) tail -n "$lines" /var/log/sing-box.log 2>/dev/null || warn "未找到 /var/log/sing-box.log。" ;;
  esac
}

# ---- network helpers (lightweight, no-cache — used in creation flows) ----
detect_public_ipv4() {
  command_exists curl || return 1
  local response
  response=$({ curl -4 --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null || true; } | tr -d '[:space:]')
  if validate_ipv4 "$response"; then printf '%s' "$response"; return 0; fi
  response=$({ curl -4 --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 3 --max-time 5 https://checkip.amazonaws.com 2>/dev/null || true; } | tr -d '[:space:]')
  if validate_ipv4 "$response"; then printf '%s' "$response"; return 0; fi
  local raw
  raw=$(curl -4 --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 3 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
  response=$(awk -F= '$1=="ip" {print $2; exit}' <<<"$raw" | tr -d '[:space:]')
  if validate_ipv4 "$response"; then printf '%s' "$response"; return 0; fi
  return 1
}
detect_public_ipv6() {
  command_exists curl || return 1
  local response
  response=$({ curl -6 --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 3 --max-time 5 https://api6.ipify.org 2>/dev/null || true; } | tr -d '[:space:]')
  if validate_ip_literal "$response" && ! validate_ipv4 "$response"; then printf '%s' "$response"; return 0; fi
  local raw
  raw=$(curl -6 --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --connect-timeout 3 --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
  response=$(awk -F= '$1=="ip" {print $2; exit}' <<<"$raw" | tr -d '[:space:]')
  if validate_ip_literal "$response" && ! validate_ipv4 "$response"; then printf '%s' "$response"; return 0; fi
  return 1
}

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

# ---- package manager (no cache — pkg_manager is cached in cache.sh) ----
install_packages() {
  local manager
  manager=$(pkg_manager) || die "无法识别包管理器。"
  case $manager in
    apk) run_bounded 180 apk add --no-cache "$@" ;;
    apt)
      if ! DEBIAN_FRONTEND=noninteractive platform_apt_get update -y; then
        warn "APT 软件索引更新失败或超时，尝试使用现有索引继续安装。"
      fi
      DEBIAN_FRONTEND=noninteractive platform_apt_get install -y --no-install-recommends "$@" \
        || die "APT 依赖安装失败，请检查软件源、DNS 和服务器网络。"
      ;;
    dnf) run_bounded 180 dnf install -y "$@" ;;
    yum) run_bounded 180 yum install -y "$@" ;;
    pacman) run_bounded 180 pacman -Sy --noconfirm --needed "$@" ;;
    zypper) run_bounded 180 zypper --non-interactive install "$@" ;;
  esac
}

ensure_dependencies() {
  require_root "$@"
  local missing=() c
  for c in curl jq openssl; do command_exists "$c" || missing+=("$c"); done
  ((${#missing[@]} == 0)) || install_packages "${missing[@]}"
}
