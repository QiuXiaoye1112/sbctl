#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

SBCTL_TESTING=1 source ./sbctl.sh

test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
CONFIG_FILE="$test_dir/config.json"
cat >"$CONFIG_FILE" <<'JSON'
{"inbounds":[{"type":"anytls","tag":"anytls-reality","users":[{"name":"old","password":"secret"}]}]}
JSON

ensure_dependencies() { :; }
ensure_config() { :; }
inbound_exists() { :; }
client_exists() { [[ $2 == old ]]; }
list_clients() { printf 'unexpected full client list\n'; }
select_client() { printf -v "$1" '%s' old; }
apply_candidate() { :; }

output=$(rename_client anytls-reality '' new)
[[ $output != *'unexpected full client list'* ]]

printf 'client unit checks passed.\n'
