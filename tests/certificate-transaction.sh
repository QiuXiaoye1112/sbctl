#!/usr/bin/env bash

set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sbctl-cert-transaction.XXXXXX")
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

export SBCTL_TESTING=1
export SBCTL_CONFIG_DIR="$TEST_ROOT/config"
export SBCTL_META_FILE="$TEST_ROOT/meta.json"
export SBCTL_CERT_DIR="$TEST_ROOT/certs"
export SBCTL_TMP_DIR="$TEST_ROOT/tmp"

mkdir -p "$SBCTL_CONFIG_DIR" "$SBCTL_CERT_DIR" "$SBCTL_TMP_DIR"
printf '%s\n' '{"schema":2,"inbounds":{},"certificates":{"example.com":{"source":"old"}},"managedResources":{},"migrations":{}}' >"$SBCTL_META_FILE"
printf 'old certificate\n' >"$SBCTL_CERT_DIR/example.com.crt"
printf 'old key\n' >"$SBCTL_CERT_DIR/example.com.key"

grep -Fq 'apk) install_packages python3 py3-pip py3-virtualenv' "$ROOT/src/certificate/certbot.sh"

source "$ROOT/sbctl.sh"
trap - ERR

ensure_dependencies() { :; }
validate_certificate_pair() { :; }
certificate_server_names() { printf 'example.com\n'; }
replace_certificate_pair() {
  printf 'new certificate\n' >"$3"
  printf 'new key\n' >"$4"
  printf -v "$5" '%s' 1
}
meta_cert_set() { return 1; }
if import_certificate example.com ignored.crt ignored.key; then
  printf 'metadata failure unexpectedly succeeded\n' >&2
  exit 1
fi
[[ $(<"$SBCTL_CERT_DIR/example.com.crt") == 'old certificate' ]]
[[ $(<"$SBCTL_CERT_DIR/example.com.key") == 'old key' ]]
[[ $(jq -r '.certificates["example.com"].source' "$SBCTL_META_FILE") == old ]]

chmod 640 "$SBCTL_CERT_DIR/example.com.crt" "$SBCTL_CERT_DIR/example.com.key"
snapshot=''
certificate_transaction_snapshot snapshot "$SBCTL_CERT_DIR/example.com.crt" "$SBCTL_CERT_DIR/example.com.key"
printf 'new certificate\n' >"$SBCTL_CERT_DIR/example.com.crt"
printf 'new key\n' >"$SBCTL_CERT_DIR/example.com.key"
printf '%s\n' '{"schema":2,"inbounds":{},"certificates":{"example.com":{"source":"new"}},"managedResources":{},"migrations":{}}' >"$SBCTL_META_FILE"
certificate_transaction_rollback "$snapshot" "$SBCTL_CERT_DIR/example.com.crt" "$SBCTL_CERT_DIR/example.com.key"
[[ $(<"$SBCTL_CERT_DIR/example.com.crt") == 'old certificate' ]]
[[ $(<"$SBCTL_CERT_DIR/example.com.key") == 'old key' ]]
[[ $(jq -r '.certificates["example.com"].source' "$SBCTL_META_FILE") == old ]]
[[ $(stat -c %a "$SBCTL_CERT_DIR/example.com.crt") == 640 && $(stat -c %a "$SBCTL_CERT_DIR/example.com.key") == 640 ]]

rm -f "$SBCTL_CERT_DIR/example.com.crt" "$SBCTL_CERT_DIR/example.com.key" "$SBCTL_META_FILE"
snapshot=''
certificate_transaction_snapshot snapshot "$SBCTL_CERT_DIR/example.com.crt" "$SBCTL_CERT_DIR/example.com.key"
printf 'new certificate\n' >"$SBCTL_CERT_DIR/example.com.crt"
printf 'new key\n' >"$SBCTL_CERT_DIR/example.com.key"
printf '%s\n' '{"schema":2,"inbounds":{},"certificates":{},"managedResources":{},"migrations":{}}' >"$SBCTL_META_FILE"
certificate_transaction_rollback "$snapshot" "$SBCTL_CERT_DIR/example.com.crt" "$SBCTL_CERT_DIR/example.com.key"
[[ ! -e $SBCTL_CERT_DIR/example.com.crt ]]
[[ ! -e $SBCTL_CERT_DIR/example.com.key ]]
[[ ! -e $SBCTL_META_FILE ]]

# A stopped service must be restarted when Certbot is missing, and a failed
# restart must remain visible to the outer recovery trap.
meta_cert_exists() { :; }
meta_cert_get_field() { case $2 in certName) printf example.com;; validation) printf http-standalone;; esac; }
detect_port80_owner() { printf sing-box; }
service_is_active() { :; }
service_stop() { :; }
service_start() { printf 'start\n' >>"$TEST_ROOT/starts"; return "${START_FAIL:-0}"; }
CERTBOT_BIN="$TEST_ROOT/missing-certbot"
CERT_STOPPED_SERVICE=0
if renew_one_certificate example.com; then exit 1; fi
[[ $(wc -l <"$TEST_ROOT/starts") == 1 && $CERT_STOPPED_SERVICE == 0 ]]
START_FAIL=1
if renew_one_certificate example.com; then exit 1; fi
[[ $CERT_STOPPED_SERVICE == 1 ]]

printf 'certificate transactions restore certificate pairs and metadata\n'
