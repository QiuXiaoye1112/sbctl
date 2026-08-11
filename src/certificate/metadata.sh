# Certificate/resource metadata helpers.
# Canonical init_meta, require_root, and meta primitives live in core.sh.
# This file provides certificate-specific metadata query/update functions.

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
