# Supported inbound set and creation flow.
# Mixed(SOCKS+HTTP) is intentionally not offered or created by sbctl.

hy2_port_in_range() {
  local port=$1 range=$2 start end
  start=${range%-*}; end=${range#*-}
  validate_port "$port" && validate_hy2_hop_range "$range" || return 1
  ((10#$port >= 10#$start && 10#$port <= 10#$end))
}

hy2_internal_port_available() {
  local port=$1 range=$2
  validate_port "$port" || return 1
  hy2_port_in_range "$port" "$range" && return 1
  port_in_config "$port" && return 1
  port_in_use_os "$port" && return 1
  return 0
}

hy2_pick_internal_port() {
  local __var=$1 range=$2 candidate hex i
  for ((i=0; i<256; i++)); do
    hex=$(random_hex 2)
    candidate=$((10000 + (16#$hex % 55536)))
    if hy2_internal_port_available "$candidate" "$range"; then
      printf -v "$__var" '%s' "$candidate"
      return 0
    fi
  done
  for ((candidate=10000; candidate<=65535; candidate++)); do
    if hy2_internal_port_available "$candidate" "$range"; then
      printf -v "$__var" '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

prompt_hy2_internal_port() {
  local __var=$1 range=$2 value=""
  while true; do
    prompt_optional value "内部监听端口（留空自动选择）" || return 1
    if [[ -z $value ]]; then
      hy2_pick_internal_port value "$range" || { error "找不到可用的内部监听端口。"; return 1; }
      info "内部监听端口：${value}"
      printf -v "$__var" '%s' "$value"
      return 0
    fi
    validate_port "$value" || { warn "端口必须为 1-65535。"; continue; }
    hy2_port_in_range "$value" "$range" && { warn "内部监听端口不能位于跳跃端口范围 ${range} 内。"; continue; }
    port_in_config "$value" && { warn "该端口已被其他 sing-box 入站使用。"; continue; }
    port_in_use_os "$value" && { warn "系统检测到该端口已被占用，请换一个端口。"; continue; }
    printf -v "$__var" '%s' "$value"
    return 0
  done
}

_legacy_build_inbound_removed() { :; }  # Canonical build_inbound lives in inbound.sh

# Canonical build_inbound lives in inbound.sh

# Canonical show_help lives in menu.sh
