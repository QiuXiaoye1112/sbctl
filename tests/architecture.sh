#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

MODULE_DIR=lib
[[ ! -d src ]] || MODULE_DIR=src

bash -n sbctl.sh install.sh "$MODULE_DIR"/*.sh tests/*.sh
sh -n alpine/install.sh

if rg -n '^[[:space:]]*(source|\.)[[:space:]]+' "$MODULE_DIR"/*.sh; then
  printf 'architecture error: modules must not source each other\n' >&2
  exit 1
fi

definitions=$(mktemp)
duplicates=$(mktemp)
trap 'rm -f "$definitions" "$duplicates"' EXIT
perl -ne 'print "$1\n" if /^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{/' \
  "$MODULE_DIR"/*.sh | sort >"$definitions"
uniq -d "$definitions" >"$duplicates"

if [[ $MODULE_DIR == lib ]]; then
  # Pre-refactor debt is frozen so a new override cannot be added unnoticed.
  expected=$'apt_get_guarded\ncertbot_cmd\ndepend\nensure_certbot_environment'
  [[ $(<"$duplicates") == "$expected" ]] || {
    printf 'architecture error: legacy duplicate-function set changed:\n' >&2
    cat "$duplicates" >&2
    exit 1
  }
else
  [[ ! -s $duplicates ]] || {
    printf 'architecture error: duplicate production functions:\n' >&2
    cat "$duplicates" >&2
    exit 1
  }
fi

printf 'architecture checks passed (%s).\n' "$MODULE_DIR"
