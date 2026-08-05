# Certificate/resource metadata extension.
# Keeps old sbctl metadata compatible while adding certificate ownership data.

# Test harnesses run as an unprivileged CI user with all paths redirected to a
# temporary directory. Keep production root enforcement unchanged.
require_root() {
  [[ ${SBCTL_TESTING:-0} == 1 ]] && return 0
  is_root || die "此操作需要 root 权限，请使用 sudo sbctl $*."
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

# Override core.sh's schema-1 init_meta without changing existing inbound metadata.
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

meta_cert_exists() {
  init_meta
  jq -e --arg id "$1" '.certificates[$id] != null' "$META_FILE" >/dev/null 2>&1
}

meta_cert_set() {
  local identifier=$1 subject=$2 cert_name=$3 source=$4 validation=$5 auto_renew=${6:-true} tmp
  init_meta; tmp=$(temp_file)
  jq --arg id "$identifier" --arg subject "$subject" --arg certName "$cert_name" \
     --arg source "$source" --arg validation "$validation" --arg autoRenew "$auto_renew" \
     --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
    .certificates[$id]={subject:$subject,certName:$certName,source:$source,validation:$validation,
      autoRenew:($autoRenew=="true"),updatedAt:$now}
  ' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
}

meta_cert_delete() {
  local identifier=$1 tmp
  init_meta; tmp=$(temp_file)
  jq --arg id "$identifier" 'del(.certificates[$id])' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
}

meta_cert_get_field() {
  init_meta
  jq -r --arg id "$1" --arg field "$2" '.certificates[$id][$field] | if . == null then empty else . end' "$META_FILE"
}

meta_cert_list() {
  init_meta
  jq -r '.certificates | keys[]' "$META_FILE" 2>/dev/null
}

meta_cert_auto_renew_certs() {
  init_meta
  jq -r '.certificates | to_entries[] | select(.value.autoRenew == true) | .key' "$META_FILE" 2>/dev/null
}

meta_resource_register() {
  local key=$1 value=$2 tmp
  init_meta; tmp=$(temp_file)
  jq --arg key "$key" --arg value "$value" '.managedResources[$key]=$value' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
}

meta_resource_get() {
  init_meta
  jq -r --arg key "$1" '.managedResources[$key] // empty' "$META_FILE"
}

meta_resource_remove() {
  local key=$1 tmp
  init_meta; tmp=$(temp_file)
  jq --arg key "$key" 'del(.managedResources[$key])' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
}
