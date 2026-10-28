#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export SBCTL_TESTING=1 SBCTL_CONFIG_DIR="$TMP" SBCTL_CONFIG_FILE="$TMP/config.json" SBCTL_META_FILE="$TMP/meta.json"
source ./sbctl.sh
trap - ERR
trap 'rm -rf "$TMP"' EXIT
printf '{"inbounds":[]}\n' >"$CONFIG_FILE"
detect_public_ipv4() { :; }
detect_public_ipv6() { :; }
meta_cert_list() { :; }
port_in_use_os() { return 1; }
# Each prefix stops at a different prompt in the SOCKS builder. Call under
# an if to exercise Bash's suppressed-errexit behavior used by add_inbound.
for input in '' $'5\n' $'5\ntest\n' $'5\ntest\n127.0.0.1\n' $'5\ntest\n127.0.0.1\nexample.com\n' $'5\ntest\n127.0.0.1\nexample.com\n12345\n' $'5\ntest\n127.0.0.1\nexample.com\n12345\nuser\n'; do
  printf '%s' "$input" >"$TMP/input"
  json=unchanged host=unchanged public=unchanged hop=unchanged
  if build_inbound json host public hop <"$TMP/input" >"$TMP/output" 2>&1; then
    printf 'expected cancellation for prefix %q\n' "$input" >&2; exit 1
  fi
  [[ $json == unchanged && $host == unchanged && $public == unchanged && $hop == unchanged ]]
  jq -e '.inbounds == []' "$CONFIG_FILE" >/dev/null
done
certificate_server_names() { printf '%s\n' a.example b.example; }
sni=unchanged
if prompt_certificate_server_name sni ignored </dev/null >"$TMP/output" 2>&1; then
  printf 'expected certificate selection cancellation\n' >&2; exit 1
fi
[[ $sni == unchanged ]]
printf 'input cancellation checks passed.\n'
