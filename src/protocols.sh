# shellcheck shell=bash
# Builders for ordinary inbound protocols. Interaction and persistence belong
# to inbound.sh; these functions only construct sing-box JSON objects.

protocol_capability() {
  local type=$1 capability=$2
  case "$type:$capability" in
    vless:tls|vless:reality|vless:users|anytls:tls|anytls:reality|anytls:users|trojan:tls|trojan:reality|trojan:users|socks:users|http:users) return 0;;
    *) return 1;;
  esac
}

protocol_build_anytls() {
  local __out=$1 tag=$2 listen=$3 port=$4 name=$5 password=$6 tls=$7
  printf -v "$__out" '%s' "$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg name "$name" --arg password "$password" --argjson tls "$tls" \
    '{type:"anytls",tag:$tag,listen:$listen,listen_port:$port,users:[{name:$name,password:$password}],tls:$tls}')"
}

protocol_build_vless() {
  local __out=$1 tag=$2 listen=$3 port=$4 name=$5 uuid=$6 flow=$7 tls=${8-} transport=${9:-null} tls_json
  [[ -n $tls ]] && tls_json=$tls || tls_json='{}'
  printf -v "$__out" '%s' "$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg name "$name" --arg uuid "$uuid" --arg flow "$flow" --argjson tls "$tls_json" --argjson transport "$transport" '
    {type:"vless",tag:$tag,listen:$listen,listen_port:$port,users:[{name:$name,uuid:$uuid,flow:$flow}]} +
    (if $tls!={} then {tls:$tls} else {} end) +
    (if $transport!=null then {transport:$transport} else {} end)')"
}

protocol_build_trojan() {
  local __out=$1 tag=$2 listen=$3 port=$4 name=$5 password=$6 tls=$7 transport=${8:-null}
  printf -v "$__out" '%s' "$(jq -n --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg name "$name" --arg password "$password" --argjson tls "$tls" --argjson transport "$transport" '
    {type:"trojan",tag:$tag,listen:$listen,listen_port:$port,users:[{name:$name,password:$password}],tls:$tls} +
    (if $transport!=null then {transport:$transport} else {} end)')"
}

protocol_build_proxy() {
  local __out=$1 type=$2 tag=$3 listen=$4 port=$5 username=${6-} password=${7-}
  if [[ -n $username ]]; then
    printf -v "$__out" '%s' "$(jq -n --arg type "$type" --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg user "$username" --arg pass "$password" \
      '{type:$type,tag:$tag,listen:$listen,listen_port:$port,users:[{username:$user,password:$pass}]}')"
  else
    printf -v "$__out" '%s' "$(jq -n --arg type "$type" --arg tag "$tag" --arg listen "$listen" --argjson port "$port" \
      '{type:$type,tag:$tag,listen:$listen,listen_port:$port,users:[]}')"
  fi
}
