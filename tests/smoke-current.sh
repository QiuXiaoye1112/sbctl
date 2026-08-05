#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp "$ROOT/tests/.smoke-current.XXXXXX.sh")
trap 'rm -f "$TMP"' EXIT

awk '
  /^run_generated_case mixed / { skip=1; next }
  skip && /^HY=/ { skip=0 }
  !skip { print }
' "$ROOT/tests/smoke.sh" \
  | sed "s#'socks://127\\.0\\.0\\.1:24449'#'@127.0.0.1:24449'#" \
  >"$TMP"

SBCTL_TESTING=1 bash "$TMP"
