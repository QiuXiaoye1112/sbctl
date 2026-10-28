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

# Explicit confirmation deletes a named user, but never opens an authenticated proxy.
cat >"$CONFIG_FILE" <<'JSON'
{"inbounds":[{"type":"socks","tag":"proxy","users":[{"username":"one","password":"secret"},{"username":"two","password":"secret"}]}]}
JSON
client_exists() { jq -e --arg tag "$1" --arg name "$2" '.inbounds[]|select(.tag==$tag)|.users[]?|select(.username==$name)' "$CONFIG_FILE" >/dev/null; }
apply_candidate() { cp "$1" "$CONFIG_FILE"; }
confirm() { return 1; }
delete_client proxy one 1
jq -e '.inbounds[0].users|length==1' "$CONFIG_FILE" >/dev/null
! delete_client proxy two 1 >/dev/null 2>&1
jq -e '.inbounds[0].users[0].username=="two"' "$CONFIG_FILE" >/dev/null

# Cancellation and rejected candidates must not change the configuration or report success.
before=$(cat "$CONFIG_FILE")
prompt_value() { return 1; }
! add_client proxy >/dev/null 2>&1
! rename_client proxy two >/dev/null 2>&1
[[ $(cat "$CONFIG_FILE") == "$before" ]]
prompt_value() { printf -v "$1" '%s' new; }
prompt_secret() { return 1; }
! add_client proxy >/dev/null 2>&1
[[ $(cat "$CONFIG_FILE") == "$before" ]]
apply_candidate() { return 1; }
prompt_secret() { printf -v "$1" '%s' secret; }
! add_client proxy >/dev/null 2>&1
! rename_client proxy two new >/dev/null 2>&1
! rotate_client_credential proxy two >/dev/null 2>&1
# Use two users so the last-user guard does not intercept the failure.
jq '.inbounds[0].users += [{username:"three",password:"secret"}]' "$CONFIG_FILE" >"$test_dir/next"
mv "$test_dir/next" "$CONFIG_FILE"
before=$(cat "$CONFIG_FILE")
! delete_client proxy two 1 >/dev/null 2>&1
[[ $(cat "$CONFIG_FILE") == "$before" ]]
