#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

bash scripts/build.sh
bash tests/architecture.sh
bash tests/unit/core.sh
bash tests/unit/protocols.sh
bash tests/unit/protocol-registry.sh
bash tests/unit/inbound-build.sh
bash tests/unit/share.sh
bash tests/unit/inbound-modify.sh
bash tests/unit/clients.sh
bash tests/integration/state-transaction.sh
bash tests/sing-box-install.sh
bash tests/outbound.sh
bash tests/outbound-domain.sh
bash tests/coexistence.sh
bash tests/smoke/cli.sh
bash tests/smoke/installer.sh

printf 'portable test suite passed.\n'
