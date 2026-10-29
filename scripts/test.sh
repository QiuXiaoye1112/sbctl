#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

bash scripts/build.sh
bash tests/architecture.sh
bash tests/unit/core.sh
bash tests/unit/input-cancellation.sh
bash tests/unit/readonly-external-cert.sh
bash tests/unit/cert-timer-failure.sh
bash tests/unit/local-ip-detection.sh
bash tests/unit/protocols.sh
bash tests/unit/protocol-registry.sh
bash tests/unit/inbound-build.sh
bash tests/unit/share.sh
bash tests/unit/inbound-modify.sh
bash tests/unit/menu-rename.sh
bash tests/unit/clients.sh
bash tests/unit/traffic.sh
bash tests/unit/traffic-rename-disabled.sh
bash tests/unit/traffic-switch-failure.sh
bash tests/unit/traffic-timer-rollback.sh
bash tests/unit/traffic-iptables-rollback.sh
bash tests/unit/uninstall-failure.sh
bash tests/integration/state-transaction.sh
bash tests/integration/restore-safety.sh
bash tests/integration/backup-ownership.sh
bash tests/legacy-config.sh
bash tests/integration/domain-templates.sh
bash tests/sing-box-install.sh
bash tests/outbound.sh
bash tests/outbound-domain.sh
bash tests/coexistence.sh
bash tests/smoke/cli.sh
bash tests/smoke/installer.sh

printf 'portable test suite passed.\n'
