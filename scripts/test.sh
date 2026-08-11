#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

bash scripts/build.sh
bash tests/architecture.sh
bash tests/unit/core.sh
bash tests/unit/protocols.sh
bash tests/unit/clients.sh
bash tests/integration/state-transaction.sh
bash tests/smoke/cli.sh
bash tests/smoke/installer.sh

printf 'portable test suite passed.\n'
