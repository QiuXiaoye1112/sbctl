#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

MODULE_DIR=lib
[[ ! -d src ]] || MODULE_DIR=src

bash -n sbctl.sh install.sh "$MODULE_DIR"/*.sh "$MODULE_DIR"/*/*.sh tests/*.sh
sh -n alpine/install.sh

if rg -n '^[[:space:]]*(source|\.)[[:space:]]+' "$MODULE_DIR"; then
  printf 'architecture error: modules must not source each other\n' >&2
  exit 1
fi

definitions=$(mktemp)
duplicates=$(mktemp)
trap 'rm -f "$definitions" "$duplicates"' EXIT
find "$MODULE_DIR" -type f -name '*.sh' -print0 | sort -z | xargs -0 perl -ne \
  'print "$1\n" if /^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{/' | sort >"$definitions"
uniq -d "$definitions" >"$duplicates"

[[ ! -s $duplicates ]] || {
  printf 'architecture error: duplicate production functions:\n' >&2
  cat "$duplicates" >&2
  exit 1
}

printf 'architecture checks passed (%s).\n' "$MODULE_DIR"
