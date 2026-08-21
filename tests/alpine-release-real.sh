#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sbctl-real-alpine.XXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT

version=${SBCTL_REAL_ALPINE_VERSION:-1.13.19}
export SBCTL_TESTING=1
export SBCTL_CONFIG_DIR="$TEST_ROOT/config"
export SBCTL_CONFIG_FILE="$TEST_ROOT/config/config.json"
export SBCTL_META_FILE="$TEST_ROOT/meta.json"
export SBCTL_CERT_DIR="$TEST_ROOT/config/certs"
export SBCTL_SING_BOX_RELEASE_INSTALL_PATH="$TEST_ROOT/bin/sing-box"

source ./sbctl.sh
install_sing_box_release_binary "$version"
"$SBCTL_SING_BOX_RELEASE_INSTALL_PATH" version | grep -F "sing-box version ${version}"

printf 'real Alpine sing-box %s release check passed.\n' "$version"
