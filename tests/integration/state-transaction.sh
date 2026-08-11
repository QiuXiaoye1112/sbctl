#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

CASE_DIR=$(mktemp -d)
trap 'rm -rf "$CASE_DIR"' EXIT
mkdir -p "$CASE_DIR/config" "$CASE_DIR/certs"

SBCTL_TESTING=1 \
SBCTL_CONFIG_DIR="$CASE_DIR/config" \
SBCTL_CONFIG_FILE="$CASE_DIR/config/config.json" \
SBCTL_META_FILE="$CASE_DIR/meta.json" \
SBCTL_CERT_DIR="$CASE_DIR/certs" \
SBCTL_BACKUP_DIR="$CASE_DIR/backups" \
SBCTL_LOCK_FILE="$CASE_DIR/lock" \
bash <<'BASH'
set -Eeuo pipefail
source ./sbctl.sh

sing_box_installed() { return 1; }
service_is_active() { return 0; }
service_restart() { return 0; }
restart_service_checked() { return 1; }

write_default_config
init_meta
candidate=$(temp_file)
meta_candidate=$(temp_file)
jq '.inbounds += [{type:"socks",tag:"candidate",listen:"127.0.0.1",listen_port:32001,users:[]}]' \
  "$CONFIG_FILE" >"$candidate"
jq '.inbounds.candidate={host:"example.com"}' "$META_FILE" >"$meta_candidate"

if apply_candidate_with_meta "$candidate" "$meta_candidate"; then
  printf 'transaction unexpectedly succeeded\n' >&2
  exit 1
fi

[[ $(jq '.inbounds | length' "$CONFIG_FILE") == 0 ]]
[[ $(jq -r '.inbounds.candidate // empty' "$META_FILE") == '' ]]
BASH

printf 'state transaction integration checks passed.\n'
