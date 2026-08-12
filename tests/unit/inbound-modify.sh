#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export SBCTL_TESTING=1
export SBCTL_CONFIG_DIR="$TMP/config"
export SBCTL_CONFIG_FILE="$TMP/config/config.json"
export SBCTL_META_FILE="$TMP/meta.json"
export SBCTL_CERT_DIR="$TMP/config/certs"
export SBCTL_LOCK_FILE="$TMP/lock"
source ./sbctl.sh

ensure_dependencies() { :; }
require_supported_core() { :; }
hy2_hop_sync() { :; }

active_case=basic
security_choice=2
apply_mode=success

seed_config() {
  write_default_config
  jq '.inbounds += [{type:"vless",tag:"vless-edit",listen:"0.0.0.0",listen_port:443,users:[{name:"u",uuid:"00000000-0000-0000-0000-000000000001",flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:"old.example.com",reality:{enabled:true,handshake:{server:"target.example.com",server_port:443},private_key:"old-private",short_id:["oldsid"]}}}]' "$CONFIG_FILE" >"$CONFIG_FILE.tmp"
  mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  printf '%s\n' '{"schema":2,"inbounds":{"vless-edit":{"host":"old-client.example.com","realityPublicKey":"old-public"}},"certificates":{},"managedResources":{},"migrations":{}}' >"$META_FILE"
}

prompt_value() {
  local __var=$1 prompt=$2
  case "$active_case:$prompt" in
    basic:监听地址) printf -v "$__var" '%s' 127.0.0.1 ;;
    *) printf -v "$__var" '%s' '' ;;
  esac
}

prompt_port() { printf -v "$1" '%s' 24443; }
prompt_public_host() {
  if [[ $active_case == basic ]]; then printf -v "$1" '%s' basic-client.example.com
  else printf -v "$1" '%s' reality-client.example.com
  fi
}

choose() { printf -v "$1" '%s' "$security_choice"; }

build_certificate_tls() {
  printf -v "$1" '%s' '{"enabled":true,"server_name":"cert2.example.com","certificate_path":"/tmp/cert2.crt","key_path":"/tmp/cert2.key"}'
  [[ -z ${2-} ]] || printf -v "$2" '%s' cert2.example.com
}

build_reality_tls() {
  printf -v "$1" '%s' '{"enabled":true,"server_name":"reality2.example.com","reality":{"enabled":true,"handshake":{"server":"target2.example.com","server_port":8443},"private_key":"new-private","short_id":["new-sid"]}}'
  printf -v "$2" '%s' new-public
}

build_inbound_meta_candidate() {
  local tag=$1 host=$2 public=$3 config_candidate=$4 meta_candidate=$5
  jq --arg tag "$tag" --arg host "$host" --arg public "$public" \
    '.inbounds[$tag]=((.inbounds[$tag]//{})+{host:$host}) |
     if $public != "" then .inbounds[$tag].realityPublicKey=$public else del(.inbounds[$tag].realityPublicKey) end' \
    "$META_FILE" >"$meta_candidate"
}

apply_candidate_with_meta() {
  [[ $apply_mode == success ]] || return 1
  install -m 600 "$1" "$CONFIG_FILE"
  install -m 600 "$2" "$META_FILE"
}

seed_config
modify_inbound_basic vless-edit
jq -e '.inbounds[]|select(.tag=="vless-edit")|.listen=="127.0.0.1" and .listen_port==24443' "$CONFIG_FILE" >/dev/null
[[ $(jq -r '.inbounds["vless-edit"].host' "$META_FILE") == basic-client.example.com ]]

seed_config
active_case=security
security_choice=1
modify_inbound_security vless-edit
jq -e '.inbounds[]|select(.tag=="vless-edit")|.tls.reality.enabled==true and .tls.server_name=="reality2.example.com" and .users[0].flow=="xtls-rprx-vision"' "$CONFIG_FILE" >/dev/null
[[ $(jq -r '.inbounds["vless-edit"].host' "$META_FILE") == old-client.example.com ]]
[[ $(jq -r '.inbounds["vless-edit"].realityPublicKey' "$META_FILE") == new-public ]]

seed_config
active_case=security
security_choice=2
modify_inbound_security vless-edit
jq -e '.inbounds[]|select(.tag=="vless-edit")|.tls.enabled==true and (.tls.reality.enabled // false)==false and .tls.server_name=="cert2.example.com" and .tls.certificate_path=="/tmp/cert2.crt" and .users[0].flow==""' "$CONFIG_FILE" >/dev/null
[[ $(jq -r '.inbounds["vless-edit"].host' "$META_FILE") == cert2.example.com ]]
[[ $(jq -r '.inbounds["vless-edit"].realityPublicKey // empty' "$META_FILE") == '' ]]

seed_config
init_meta
before_config=$(sha256sum "$CONFIG_FILE")
before_meta=$(sha256sum "$META_FILE")
active_case=basic
apply_mode=failure
! modify_inbound_basic vless-edit
[[ $(sha256sum "$CONFIG_FILE") == "$before_config" ]]
[[ $(sha256sum "$META_FILE") == "$before_meta" ]]

printf 'inbound modify checks passed.\n'
