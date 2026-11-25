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
  jq '.inbounds += [{type:"anytls",tag:"anytls-edit",listen:"0.0.0.0",listen_port:443,users:[{name:"u",password:"secret"}],tls:{enabled:true,server_name:"old.example.com",reality:{enabled:true,handshake:{server:"target.example.com",server_port:443},private_key:"old-private",short_id:["oldsid"]}}}]' "$CONFIG_FILE" >"$CONFIG_FILE.tmp"
  mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  printf '%s\n' '{"schema":2,"inbounds":{"anytls-edit":{"host":"old-client.example.com","realityPublicKey":"old-public"}},"certificates":{},"managedResources":{},"migrations":{}}' >"$META_FILE"
}

prompt_inbound_ip() { printf -v "$1" '%s' 127.0.0.1; }
prompt_port() { printf -v "$1" '%s' 24443; }

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
  [[ -z $2 ]] || install -m 600 "$2" "$META_FILE"
}

seed_config
modify_inbound_basic anytls-edit
jq -e '.inbounds[]|select(.tag=="anytls-edit")|.listen=="127.0.0.1" and .listen_port==24443' "$CONFIG_FILE" >/dev/null
[[ $(jq -r '.inbounds["anytls-edit"].host' "$META_FILE") == 127.0.0.1 ]]

(
  seed_config
  before_meta=$(cat "$META_FILE")
  prompt_inbound_ip() { return 99; }
  modify_inbound_basic anytls-edit port
  jq -e '.inbounds[] | select(.tag=="anytls-edit") | .listen=="0.0.0.0" and .listen_port==24443' "$CONFIG_FILE" >/dev/null
  [[ $(cat "$META_FILE") == "$before_meta" ]]
)

seed_config
active_case=security
security_choice=1
modify_inbound_security anytls-edit
jq -e '.inbounds[]|select(.tag=="anytls-edit")|.tls.reality.enabled==true and .tls.server_name=="reality2.example.com"' "$CONFIG_FILE" >/dev/null
[[ $(jq -r '.inbounds["anytls-edit"].host' "$META_FILE") == old-client.example.com ]]
[[ $(jq -r '.inbounds["anytls-edit"].realityPublicKey' "$META_FILE") == new-public ]]

seed_config
active_case=security
security_choice=2
modify_inbound_security anytls-edit
jq -e '.inbounds[]|select(.tag=="anytls-edit")|.tls.enabled==true and (.tls.reality.enabled // false)==false and .tls.server_name=="cert2.example.com" and .tls.certificate_path=="/tmp/cert2.crt"' "$CONFIG_FILE" >/dev/null
[[ $(jq -r '.inbounds["anytls-edit"].host' "$META_FILE") == old-client.example.com ]]
[[ $(jq -r '.inbounds["anytls-edit"].realityPublicKey // empty' "$META_FILE") == '' ]]

seed_config
init_meta
before_config=$(sha256sum "$CONFIG_FILE")
before_meta=$(sha256sum "$META_FILE")
active_case=basic
apply_mode=failure
! modify_inbound_basic anytls-edit
[[ $(sha256sum "$CONFIG_FILE") == "$before_config" ]]
[[ $(sha256sum "$META_FILE") == "$before_meta" ]]

seed_config
apply_mode=success
if modify_inbound_transport anytls-edit; then printf 'AnyTLS transport edit must fail\n' >&2; exit 1; fi

jq '.inbounds += [
  {type:"hysteria2",tag:"hy2-edit",listen_port:8443,up_mbps:120,down_mbps:240,
   tls:{enabled:true,server_name:"hy2.example.com"},users:[{name:"u",password:"fixture-only"}]},
  {type:"hysteria2",tag:"hy2-other",listen_port:8444,up_mbps:50,down_mbps:60}
]' "$CONFIG_FILE" >"$TMP/with-hy2.json"
cp "$TMP/with-hy2.json" "$CONFIG_FILE"
before_meta=$(sha256sum "$META_FILE")
apply_candidate() {
  printf 'apply\n' >>"$TMP/bandwidth-applies"
  [[ $apply_mode == success ]] || return 1
  cp "$1" "$CONFIG_FILE"
}

hy2_modify_bandwidth hy2-edit <<'INPUT'
-10
200

INPUT
jq -e '.inbounds[1].up_mbps==200 and .inbounds[1].down_mbps==240' "$CONFIG_FILE" >/dev/null
hy2_modify_bandwidth hy2-edit <<< $'0\n350'
jq -e '.inbounds[1] | (has("up_mbps")|not) and .down_mbps==350' "$CONFIG_FILE" >/dev/null
hy2_modify_bandwidth hy2-edit <<< $'\n0'
jq -e '.inbounds[1] | (has("up_mbps")|not) and (has("down_mbps")|not)' "$CONFIG_FILE" >/dev/null
jq -es '.[0] == (.[1] | del(.inbounds[1].up_mbps,.inbounds[1].down_mbps))' "$CONFIG_FILE" "$TMP/with-hy2.json" >/dev/null
[[ $(sha256sum "$META_FILE") == "$before_meta" ]]

before_config=$(sha256sum "$CONFIG_FILE")
hy2_modify_bandwidth hy2-edit <<< $'\n'
hy2_modify_bandwidth hy2-edit <<< $'0\n0'
if hy2_modify_bandwidth hy2-edit <<<"310"; then printf 'unexpected success on EOF\n' >&2; exit 1; fi
if hy2_modify_bandwidth anytls-edit </dev/null; then printf 'unexpected success on AnyTLS\n' >&2; exit 1; fi
[[ $(wc -l <"$TMP/bandwidth-applies") -eq 3 ]]
[[ $(sha256sum "$CONFIG_FILE") == "$before_config" ]]

apply_mode=failure
if hy2_modify_bandwidth hy2-edit <<< $'80\n100'; then printf 'unexpected success on transaction failure\n' >&2; exit 1; fi
[[ $(sha256sum "$CONFIG_FILE") == "$before_config" ]]

printf 'inbound modify checks passed.\n'
