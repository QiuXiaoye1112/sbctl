#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

bash -n sbctl.sh install.sh src/*.sh src/*/*.sh tests/*.sh tests/*/*.sh scripts/*.sh dist/sbctl
sh -n alpine/install.sh
shellcheck -S error -x -s bash sbctl.sh install.sh src/*.sh src/*/*.sh tests/*.sh tests/*/*.sh scripts/*.sh dist/sbctl
shellcheck -S warning -s sh alpine/install.sh
git diff --check

printf 'lint checks passed.\n'
