#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export SBCTL_TESTING=1 SBCTL_CONFIG_DIR="$TMP/config" SBCTL_CONFIG_FILE="$TMP/config/config.json" SBCTL_META_FILE="$TMP/state/meta.json" SBCTL_CERT_DIR="$TMP/certs"
source ./sbctl.sh
trap - ERR
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$SBCTL_CONFIG_DIR"
printf '{"inbounds":[],"outbounds":[]}\n' >"$CONFIG_FILE"
list_certificates >/dev/null
list_domain_templates >/dev/null
list_inbound_template_bindings test >/dev/null
hy2_hop_range_for_tag test >/dev/null
hy2_hop_enabled_count >/dev/null
cloudflare_dependency_count >/dev/null
[[ ! -e $META_FILE && ! -e $CERT_DIR ]]
mkdir -p "$(dirname "$META_FILE")"
printf '%s\n' '{"inbounds":{},"certificates":{},"schema":1}' >"$META_FILE"
cp "$META_FILE" "$TMP/original-meta"
list_certificates >/dev/null
list_domain_templates >/dev/null
hy2_hop_range_for_tag test >/dev/null
cloudflare_dependency_count >/dev/null
cmp "$META_FILE" "$TMP/original-meta"
rm "$META_FILE"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 1 -subj /CN=example.com >/dev/null 2>&1
printf '%s\n%s\n' "$TMP/cert.pem" "$TMP/key.pem" >"$TMP/input"
result= host=
build_certificate_tls result host <"$TMP/input"
[[ $(jq -r .certificate_path <<<"$result") == "$TMP/cert.pem" && $host == example.com ]]
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/other.pem" >/dev/null 2>&1
printf '%s\n%s\n' "$TMP/cert.pem" "$TMP/other.pem" >"$TMP/input"
if build_certificate_tls result host <"$TMP/input"; then exit 1; fi
[[ ! -e $META_FILE && ! -e $CERT_DIR ]]
mkdir -p "$CERT_DIR"
cp "$TMP/cert.pem" "$CERT_DIR/inside.pem"
ln -s "$CERT_DIR/inside.pem" "$TMP/alias.pem"
printf '%s\n%s\n' "$TMP/alias.pem" "$TMP/key.pem" >"$TMP/input"
if build_certificate_tls result host <"$TMP/input"; then exit 1; fi
ln -s "$TMP/cert.pem" "$CERT_DIR/outside.pem"
printf '%s\n%s\n' "$CERT_DIR/outside.pem" "$TMP/key.pem" >"$TMP/input"
if build_certificate_tls result host <"$TMP/input"; then exit 1; fi
cp "$TMP/cert.pem" "$CERT_DIR/managed.crt"
cp "$TMP/key.pem" "$CERT_DIR/managed.key"
chmod 640 "$CERT_DIR/managed.crt" "$CERT_DIR/managed.key"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/new-key.pem" -out "$TMP/new-cert.pem" -days 1 -subj /CN=example.com >/dev/null 2>&1
replace_certificate_pair "$TMP/new-cert.pem" "$TMP/new-key.pem" "$CERT_DIR/managed.crt" "$CERT_DIR/managed.key"
[[ $(stat -c %a "$CERT_DIR/managed.crt") == 640 && $(stat -c %a "$CERT_DIR/managed.key") == 640 ]]
printf 'read-only metadata and external certificate checks passed.\n' 
