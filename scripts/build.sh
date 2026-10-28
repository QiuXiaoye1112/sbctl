#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

MODULES=()
while IFS= read -r module; do MODULES+=("$module"); done < <(
  sed -n '/^SBCTL_MODULES=(/,/^)/p' sbctl.sh \
    | sed -n 's/^[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p'
)
((${#MODULES[@]} > 0)) || { printf 'could not read module order from sbctl.sh\n' >&2; exit 1; }

mkdir -p dist
candidate=$(mktemp "${TMPDIR:-/tmp}/sbctl-dist.XXXXXX")
trap 'rm -f "$candidate"' EXIT

sed '/^# BEGIN MODULE LOADER$/,$d' sbctl.sh >"$candidate"
source_commit=${SBCTL_BUILD_COMMIT:-$(git rev-parse --short=12 HEAD 2>/dev/null || printf unknown)}
[[ $source_commit =~ ^[a-zA-Z0-9._-]+$ ]] || { printf 'invalid build commit\n' >&2; exit 1; }
sed -i "s/^readonly SBCTL_BUILD_COMMIT=.*/readonly SBCTL_BUILD_COMMIT=\"$source_commit\"/" "$candidate"
printf '\n# Built from modular sources by scripts/build.sh.\n' >>"$candidate"
for module in "${MODULES[@]}"; do
  source_file="src/${module}.sh"
  [[ -r $source_file ]] || { printf 'missing module: %s\n' "$source_file" >&2; exit 1; }
  printf '\n# ---- module: %s ----\n' "$module" >>"$candidate"
  sed '1{/^# shellcheck shell=bash$/d;}' "$source_file" >>"$candidate"
done
awk 'emit {print} /^# END MODULE LOADER$/ {emit=1}' sbctl.sh >>"$candidate"

chmod 755 "$candidate"
bash -n "$candidate"
mv -f "$candidate" dist/sbctl
trap - EXIT
printf 'built dist/sbctl\n'
