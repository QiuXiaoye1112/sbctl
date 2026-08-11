#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

if grep -RniE 'ufw|firewalld|firewall' sbctl.sh install.sh alpine/install.sh src; then
  echo 'firewall-related code must not exist in sbctl runtime files' >&2
  exit 1
fi

[[ ! -e src/system_ext.sh ]] || {
  echo 'obsolete src/system_ext.sh must stay removed' >&2
  exit 1
}

printf 'no-firewall guard passed.\n'
