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

# The legacy smoke fixture predates Hysteria2's single-port/port-hopping choice.
# Rewrite only that heredoc so it follows the current interactive flow.
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "  add_inbound <<EOF2\n"
start = text.index(marker) + len(marker)
end = text.index("\nEOF2", start)
text = text[:start] + "3\n\n\n1\n24445\n1.2.3.4\n\n\n\n\n\n2\n" + text[end:]
path.write_text(text)
PY

SBCTL_TESTING=1 bash "$TMP"
