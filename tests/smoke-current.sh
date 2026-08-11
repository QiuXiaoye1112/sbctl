#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SBCTL_TESTING=1 TERM="${TERM:-xterm}" bash "$ROOT/tests/smoke.sh"
