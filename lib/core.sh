# shellcheck shell=bash
# sbctl core — colors, logging, validators, I/O helpers, and metadata primitives.
# Session-cached state functions live in lib/cache.sh (loaded before this file).

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""; C_RESET=""
fi

info()    { printf '%s[信息]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf '%s[警告]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error()   { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()     { error "$*"; exit 1; }
heading() { printf '\n%s%s%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"; }
clear_screen() { clear 2>/dev/null || true; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ $(id -u) -eq 0 ]]; }
require_root() { [[ ${SBCTL_TESTING:-0} == 1 ]] && return 0; is_root || die "此操作需要 root 权限，请使用 sudo sbctl $*."; }

on_error() {
  local exit_code=$? line=${BASH_LINENO[0]:-?}
  error "命令在第 ${line} 行失败（退出码 ${exit_code}）。"
  exit "$exit_code"
}
trap on_error ERR

# Action-level cleanup: cert service restore ONLY.
# Safe to run in subshells (run_menu_action) — does NOT delete session cache or lock.
cleanup_action_on_exit() {
  if [[ ${CERT_STOPPED_SERVICE:-0} == 1 ]]; then
    service_start >/dev/null 2>&1 || true
    CERT_STOPPED_SERVICE=0
  fi
}

# Session-level cleanup: cache + lock + action cleanup.
# Only runs on outermost sbctl process exit.
cleanup_session_on_exit() {
  if [[ -n ${_SBC_CACHE_DIR:-} && -d ${_SBC_CACHE_DIR:-} ]]; then
    rm -rf -- "$_SBC_CACHE_DIR" 2>/dev/null || true
  fi
  if [[ -n ${_SBC_LOCK_DIR:-} && -d ${_SBC_LOCK_DIR:-} ]]; then
    rmdir "$_SBC_LOCK_DIR" 2>/dev/null || true
  fi
  cleanup_action_on_exit
}
trap cleanup_session_on_exit EXIT

pause() {
  [[ -t 0 ]] || return 0
  read -r -p "按回车键继续..." _ || true
}

confirm() {
  local prompt=${1:-"确定继续吗？"} default=${2:-N} answer suffix
  [[ $default == Y ]] && suffix='[Y/n]' || suffix='[y/N]'
  if [[ ! -t 0 ]]; then [[ $default == Y ]]; return; fi
  read -r -p "${prompt} ${suffix} " answer || { echo; answer=${default}; }
  answer=${answer:-$default}
  [[ $answer =~ ^[Yy]$ ]]
}

prompt_value() {
  local __var=$1 prompt=$2 default=${3-} __input=""
  printf -v "$__var" '%s' ''
  while true; do
    if [[ -n $default ]]; then
      read -r -p "${prompt} [${default}]: " __input || return 1
      __input=${__input:-$default}
    else
      read -r -p "${prompt}: " __input || return 1
    fi
    [[ -n $__input ]] || { warn "此项不能为空。"; continue; }
    printf -v "$__var" '%s' "$__input"
    return 0
  done
}

prompt_optional() {
  local __var=$1 prompt=$2 __input=""
  printf -v "$__var" '%s' ''
  read -r -p "${prompt}: " __input || return 1
  printf -v "$__var" '%s' "$__input"
}

prompt_optional_positive_int() {
  local __var=$1 prompt=$2 __candidate=""
  while true; do
    prompt_optional __candidate "$prompt" || return 1
    if [[ -z $__candidate ]]; then printf -v "$__var" '%s' ""; return 0; fi
    if [[ $__candidate =~ ^[0-9]+$ ]] && ((10#$__candidate > 0)); then printf -v "$__var" '%s' "$__candidate"; return 0; fi
    warn "请输入正整数，或留空表示不限。"
  done
}

prompt_secret() {
  local __var=$1 prompt=$2 generated=${3-} __input=""
  printf -v "$__var" '%s' ''
  if [[ -n $generated ]]; then
    read -r -p "${prompt}（留空自动生成）: " __input || return 1
    __input=${__input:-$generated}
  else
    while [[ -z $__input ]]; do read -r -p "${prompt}: " __input || return 1; done
  fi
  printf -v "$__var" '%s' "$__input"
}

choose() {
  local __var=$1 prompt=$2; shift 2
  local options=("$@") __choice="" i
  printf -v "$__var" '%s' ''
  printf '%s\n' "$prompt"
  for ((i=0;i<${#options[@]};i++)); do printf '  %d) %s\n' "$((i+1))" "${options[$i]}"; done
  while true; do
    read -r -p "请选择 [1-${#options[@]}]: " __choice || { echo; return 1; }
    if [[ $__choice =~ ^[0-9]+$ ]] && ((__choice>=1 && __choice<=${#options[@]})); then
      printf -v "$__var" '%s' "$__choice"; return 0
    fi
    warn "无效选项。"
  done
}

run_menu_action() {
  local status
  set +e
  (
    set -Eeuo pipefail
    trap - ERR
    trap cleanup_action_on_exit EXIT
    "$@"
  )
  status=$?
  set -e
  ((status == 0)) || warn "操作未完成，脚本仍在运行。"
  return 0
}

# ---- validators ----
validate_port() { [[ ${1:-} =~ ^[0-9]+$ ]] && ((10#$1>=1 && 10#$1<=65535)); }
validate_tag() { [[ ${1:-} =~ ^[A-Za-z0-9_.-]+$ ]]; }
validate_domain() { [[ ${1:-} =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
validate_uuid() { [[ ${1:-} =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; }
validate_short_id() { [[ ${1:-} =~ ^[0-9A-Fa-f]{0,8}$ ]]; }
validate_ipv4() {
  local IFS=. a b c d extra
  read -r a b c d extra <<<"${1:-}"
  [[ -z ${extra:-} && $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ && $c =~ ^[0-9]+$ && $d =~ ^[0-9]+$ ]] || return 1
  ((10#$a<=255 && 10#$b<=255 && 10#$c<=255 && 10#$d<=255))
}
validate_ip_literal() { validate_ipv4 "$1" || [[ $1 == *:* && $1 =~ ^[0-9A-Fa-f:]+$ ]]; }
validate_host() { validate_domain "$1" || validate_ip_literal "$1"; }

random_hex() { openssl rand -hex "${1:-4}"; }
random_password() { openssl rand -base64 32 | tr -d '\n=+/' | cut -c1-24; }
generate_uuid() {
  if [[ -x $SING_BOX_BIN ]] && "$SING_BOX_BIN" generate uuid >/dev/null 2>&1; then
    "$SING_BOX_BIN" generate uuid | tail -n1
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
  elif command_exists uuidgen; then uuidgen | tr '[:upper:]' '[:lower:]'
  else
    local h; h=$(openssl rand -hex 16)
    printf '%s-%s-4%s-%x%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" "$(((0x${h:16:1}&3)|8))" "${h:17:3}" "${h:20:12}"
  fi
}
url_encode() { jq -rn --arg v "$1" '$v|@uri'; }
uri_host() { [[ $1 == *:* && $1 != \[*\] ]] && printf '[%s]' "$1" || printf '%s' "$1"; }

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

prompt_public_host() {
  local __var=$1 default=${2:-} v4="" v6="" choice value=""
  if [[ -z $default ]]; then
    v4=$(detect_public_ipv4 || true); v6=$(detect_public_ipv6 || true)
    if [[ -n $v4 && -n $v6 ]]; then
      choose choice "选择客户端连接地址" "IPv4  $v4" "IPv6  $v6" "域名/其他地址" || return 1
      case $choice in 1) value=$v4;; 2) value=$v6;; 3) prompt_value value "客户端连接域名/IP" || return 1;; esac
    elif [[ -n $v4 ]]; then value=$v4
    elif [[ -n $v6 ]]; then value=$v6
    else prompt_value value "客户端连接域名/IP" || return 1
    fi
  else value=$default; fi
  [[ -n $value && $value != *' '* ]] || { error "客户端连接地址无效。"; return 1; }
  printf -v "$__var" '%s' "$value"
}

# ---- bounded execution helpers ----
run_bounded() {
  local seconds=$1; shift
  if declare -F "${1:-}" >/dev/null 2>&1; then "$@"
  elif command_exists timeout; then timeout "$seconds" "$@"
  else "$@"
  fi
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

# ---- package manager (no cache — pkg_manager is cached in cache.sh) ----
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

ensure_dependencies() {
  require_root "$@"
  local missing=() c
  for c in curl jq openssl; do command_exists "$c" || missing+=("$c"); done
  ((${#missing[@]} == 0)) || install_packages "${missing[@]}"
  acquire_lock
}

acquire_lock() {
  # Re-entrant: if we already hold the lock, return immediately
  [[ ${_SBC_LOCK_HELD:-0} == 1 ]] && return 0
  mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
  if command_exists flock; then
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
      # Check for stale lock: if lock file is older than 300s, force-clear it
      local lock_age=0 now
      now=$(date +%s 2>/dev/null || printf 0)
      if [[ -f $LOCK_FILE && $now -gt 0 ]]; then
        lock_age=$(($now - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || stat -f %m "$LOCK_FILE" 2>/dev/null || printf 0)))
      fi
      if ((lock_age > 300)); then
        warn "检测到过期锁文件（${lock_age} 秒），自动清除。"
        exec 9>&-; rm -f "$LOCK_FILE"
        exec 9>"$LOCK_FILE"
        flock -n 9 || die "另一个 sbctl 操作正在运行。"
      else
        die "另一个 sbctl 操作正在运行。"
      fi
    fi
  else
    _SBC_LOCK_DIR="${LOCK_FILE}.d"
    if ! mkdir "$_SBC_LOCK_DIR" 2>/dev/null; then
      local lock_age=0 now
      now=$(date +%s 2>/dev/null || printf 0)
      if [[ -d $_SBC_LOCK_DIR && $now -gt 0 ]]; then
        lock_age=$(($now - $(stat -c %Y "$_SBC_LOCK_DIR" 2>/dev/null || stat -f %m "$_SBC_LOCK_DIR" 2>/dev/null || printf 0)))
      fi
      if ((lock_age > 300)); then
        warn "检测到过期锁目录（${lock_age} 秒），自动清除。"
        rmdir "$_SBC_LOCK_DIR" 2>/dev/null || true
        mkdir "$_SBC_LOCK_DIR" 2>/dev/null || die "另一个 sbctl 操作正在运行。"
      else
        die "另一个 sbctl 操作正在运行。"
      fi
    fi
  fi
  _SBC_LOCK_HELD=1
}

temp_file() { mktemp "${TMPDIR:-/tmp}/sbctl.XXXXXX"; }
timestamp() { date '+%Y%m%d-%H%M%S'; }

# ---- metadata primitives ----
init_meta() {
  mkdir -p "$(dirname "$META_FILE")"
  if [[ ! -s $META_FILE ]] || ! jq -e 'type=="object" and ((.inbounds // {})|type=="object")' "$META_FILE" >/dev/null 2>&1; then
    [[ ! -f $META_FILE ]] || cp -a "$META_FILE" "${META_FILE}.broken-$(timestamp)"
    _sbctl_meta_default_json >"$META_FILE"
    chmod 600 "$META_FILE"
  else
    _sbctl_meta_upgrade_file || die "无法升级 sbctl metadata。"
  fi
  _sbctl_meta_legacy_cert_scan
}

_sbctl_meta_default_json() {
  printf '%s\n' '{"schema":2,"inbounds":{},"certificates":{},"managedResources":{},"migrations":{}}'
}

_sbctl_meta_upgrade_file() {
  local tmp
  tmp=$(temp_file)
  jq '
    .schema=2 |
    .inbounds=(if (.inbounds|type)=="object" then .inbounds else {} end) |
    .certificates=(if (.certificates|type)=="object" then .certificates else {} end) |
    .managedResources=(if (.managedResources|type)=="object" then .managedResources else {} end) |
    .migrations=(if (.migrations|type)=="object" then .migrations else {} end)
  ' "$META_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
  install -m 600 "$tmp" "$META_FILE"
  rm -f "$tmp"
}

_sbctl_meta_legacy_cert_scan() {
  jq -e '.migrations.legacyCertScanV1 == true' "$META_FILE" >/dev/null 2>&1 && return 0
  local cert key id subject tmp migrated=0
  mkdir -p "$CERT_DIR"
  for cert in "$CERT_DIR"/*.crt; do
    [[ -r $cert ]] || continue
    key=${cert%.crt}.key
    [[ -r $key ]] || continue
    id=$(basename "$cert" .crt)
    jq -e --arg id "$id" '.certificates[$id] != null' "$META_FILE" >/dev/null 2>&1 && continue
    subject=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null \
      | sed -n 's/.*DNS:\([^, ]*\).*/\1/p' | head -1 || true)
    if [[ -z $subject ]]; then
      subject=$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253 2>/dev/null \
        | sed -n 's/^subject=.*CN=\([^,]*\).*$/\1/p' | head -1 || true)
    fi
    [[ -n $subject ]] || subject=$id
    tmp=$(temp_file)
    jq --arg id "$id" --arg subject "$subject" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
      .certificates[$id]={subject:$subject,certName:$id,source:"legacy",validation:"legacy",autoRenew:false,updatedAt:$now}
    ' "$META_FILE" >"$tmp"
    install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
    ((migrated+=1))
  done
  tmp=$(temp_file)
  jq '.migrations.legacyCertScanV1=true' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
  ((migrated == 0)) || info "已将 ${migrated} 张旧版证书登记到 sbctl metadata。"
}

meta_set_inbound() {
  local tag=$1 host=$2 public_key=${3-} tmp private private_sha=""
  init_meta
  if [[ -n $public_key && -f $CONFIG_FILE ]]; then
    private=$(jq -r --arg tag "$tag" '.inbounds[]?|select(.tag==$tag)|.tls.reality.private_key // empty' "$CONFIG_FILE" 2>/dev/null || true)
    [[ -z $private ]] || private_sha=$(printf '%s' "$private" | openssl dgst -sha256 -r | awk '{print $1}')
  fi
  tmp=$(temp_file)
  jq --arg tag "$tag" --arg host "$host" --arg public "$public_key" --arg privateSHA "$private_sha" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
    .inbounds[$tag]=((.inbounds[$tag]//{})+{host:$host,updatedAt:$now}) |
    if $public!="" and $privateSHA!="" then
      .inbounds[$tag].realityPublicKey=$public | .inbounds[$tag].realityPrivateSHA256=$privateSHA
    else
      del(.inbounds[$tag].realityPublicKey,.inbounds[$tag].realityPrivateSHA256)
    end' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
}
meta_set_host() {
  local tag=$1 host=$2 tmp
  init_meta; tmp=$(temp_file)
  jq --arg tag "$tag" --arg host "$host" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
    .inbounds[$tag]=((.inbounds[$tag]//{})+{host:$host,updatedAt:$now})' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
}
meta_delete_inbound() {
  local tag=$1 tmp; init_meta; tmp=$(temp_file)
  jq --arg tag "$tag" 'del(.inbounds[$tag])' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
}
public_host_for_tag() {
  local tag=$1 host=""
  init_meta
  host=$(jq -r --arg tag "$tag" '.inbounds[$tag].host // empty' "$META_FILE")
  if [[ -z $host ]]; then
    prompt_public_host host || { error "入站 ${tag} 缺少客户端连接地址；请在交互模式下修改入站并补填。"; return 1; }
    meta_set_host "$tag" "$host"
  fi
  printf '%s' "$host"
}
