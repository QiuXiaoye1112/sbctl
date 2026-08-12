#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

SBCTL_TESTING=1 source ./sbctl.sh

expected=(anytls vless hysteria2 trojan socks http)
actual=()
while IFS= read -r protocol; do actual+=("$protocol"); done < <(protocol_list)
[[ ${#actual[@]} == ${#expected[@]} ]]
for i in "${!expected[@]}"; do [[ ${actual[$i]} == "${expected[$i]}" ]]; done
[[ $(printf '%s\n' "${actual[@]}" | sort -u | wc -l | tr -d ' ') == ${#actual[@]} ]]

for protocol in "${actual[@]}"; do
  [[ -n $(protocol_display_name "$protocol") ]]
done

declare -F protocol_build_anytls >/dev/null
declare -F protocol_build_vless >/dev/null
declare -F protocol_build_trojan >/dev/null
declare -F hy2_build >/dev/null
declare -F protocol_build_proxy >/dev/null
declare -F print_share >/dev/null

for protocol in "${actual[@]}"; do
  protocol_capability "$protocol" share
  protocol_capability "$protocol" users
  client_label_field "$protocol" >/dev/null
done

for capability in users tls certificate udp port_hopping; do
  case $capability in
    users|tls|certificate|udp|port_hopping) protocol_capability hysteria2 "$capability" ;;
  esac
done
! protocol_capability hysteria2 reality
! protocol_capability hysteria2 transport

for capability in tls reality users certificate transport tcp; do protocol_capability vless "$capability"; done
for capability in tls reality users certificate transport tcp; do protocol_capability trojan "$capability"; done
for capability in tls reality users certificate tcp; do protocol_capability anytls "$capability"; done

! protocol_capability socks tls
! protocol_capability http tls

printf 'protocol registry contract checks passed.\n'
