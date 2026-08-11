# shellcheck shell=bash
# sbctl core — logging, interaction, validators, temp files, and table helpers.
# Domain and platform operations live in their dedicated modules.

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
  # ERR traps still fire when `errexit` is disabled. Temporarily remove the
  # outer session trap so a failed action can be captured instead of exiting
  # the whole interactive program. The action itself keeps strict -e behavior.
  trap - ERR
  set +e
  (
    set -Eeuo pipefail
    trap - ERR
    trap cleanup_action_on_exit EXIT
    "$@"
  )
  status=$?
  set -e
  trap on_error ERR
  ((status == 0)) || warn "操作未完成，脚本仍在运行。"
  return 0
}

# ---- validators ----
validate_port() { [[ ${1:-} =~ ^[0-9]+$ ]] && ((10#$1>=1 && 10#$1<=65535)); }
validate_tag() { [[ ${1:-} =~ ^[A-Za-z0-9_.-]+$ ]]; }
validate_domain() { [[ ${1:-} =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
validate_uuid() { [[ ${1:-} =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; }
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

prompt_public_host() {
  local __var=$1 default=${2:-} v4="" v6="" choice value=""
  if [[ -z $default ]]; then
    v4=$(detect_public_ipv4 || true); v6=$(detect_public_ipv6 || true)
    local labels=() values=() cert_id
    [[ -n $v4 ]] && { labels+=("IPv4  $v4"); values+=("$v4"); }
    [[ -n $v6 ]] && { labels+=("IPv6  $v6"); values+=("$v6"); }
    while IFS= read -r cert_id; do
      [[ -n $cert_id ]] || continue
      # Skip internal IP-cert labels (ip4-*, ip6-*), only show real domains
      [[ $cert_id == ip4-* || $cert_id == ip6-* ]] && continue
      labels+=("${cert_id} (已托管)"); values+=("$cert_id")
    done < <(meta_cert_list 2>/dev/null || true)
    labels+=("域名/其他地址"); values+=("__manual__")
    if ((${#labels[@]} == 1)); then
      prompt_value value "客户端连接域名/IP" || return 1
    else
      choose choice "选择客户端连接地址" "${labels[@]}" || return 1
      local selected="${values[$((choice-1))]}"
      if [[ $selected == __manual__ ]]; then prompt_value value "客户端连接域名/IP" || return 1; else value=$selected; fi
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

temp_file() { mktemp "${TMPDIR:-/tmp}/sbctl.XXXXXX"; }
timestamp() { date '+%Y%m%d-%H%M%S'; }

# ---- terminal table helpers ----
display_width() {
  local __var=$1 value=$2 char code computed_width=0 i
  for ((i=0; i<${#value}; i++)); do
    char=${value:i:1}
    printf -v code '%d' "'$char"
    if ((code < 0 || code > 127)); then ((computed_width+=2)); else ((computed_width+=1)); fi
  done
  printf -v "$__var" '%s' "$computed_width"
}

print_table_cell() {
  local value=$1 target_width=$2 cell_width=0 padding
  display_width cell_width "$value"
  padding=$((target_width-cell_width))
  ((padding > 0)) || padding=1
  printf '%s%*s' "$value" "$padding" ''
}

print_table_cell_clipped() {
  local value=$1 target_width=$2 cell_width=0 limit clipped="" used=0 char char_width=0 i
  display_width cell_width "$value"
  if ((cell_width < target_width)); then print_table_cell "$value" "$target_width"; return; fi
  limit=$((target_width-4)); ((limit > 0)) || limit=1
  for ((i=0; i<${#value}; i++)); do
    char=${value:i:1}; display_width char_width "$char"
    ((used+char_width <= limit)) || break
    clipped+=$char; ((used+=char_width))
  done
  print_table_cell "${clipped}..." "$target_width"
}
