# shellcheck shell=bash
# REALITY target validation helper.
# Canonical build_reality_tls lives in inbound.sh.

validate_reality_target() {
  local value=$1 host port
  [[ $value == *:* ]] || return 1
  host=${value%:*}
  port=${value##*:}
  [[ -n $host ]] && validate_port "$port"
}
