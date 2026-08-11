#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

SBCTL_TESTING=1 source ./sbctl.sh

validate_port 1
validate_port 65535
! validate_port 0
! validate_port 65536
validate_domain example.com
! validate_domain 'bad domain'
validate_uuid 550e8400-e29b-41d4-a716-446655440000
! validate_uuid not-a-uuid
validate_reality_target example.com:443
! validate_reality_target example.com
validate_hy2_hop_range 30000-50000
! validate_hy2_hop_range 50000-30000

printf 'core unit checks passed.\n'
