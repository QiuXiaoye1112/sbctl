#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sbctl-sing-box-install.XXXXXX")
export SBCTL_TESTING=1
export SBCTL_CONFIG_DIR="$TEST_ROOT/config"
export SBCTL_CONFIG_FILE="$SBCTL_CONFIG_DIR/config.json"
export SBCTL_META_FILE="$TEST_ROOT/meta.json"
export SBCTL_CERT_DIR="$SBCTL_CONFIG_DIR/certs"
export SBCTL_LOCK_FILE="$TEST_ROOT/lock"
export SBCTL_SYSTEMD_UNIT_DIR="$TEST_ROOT/systemd"
export SBCTL_OPENRC_INIT_DIR="$TEST_ROOT/openrc"
export SBCTL_SING_BOX_RELEASE_INSTALL_PATH="$TEST_ROOT/default/sing-box"
source ./sbctl.sh
trap - ERR

cleanup_test_root() {
  [[ -z ${_SBC_CACHE_DIR:-} || ! -d ${_SBC_CACHE_DIR:-} ]] || rm -rf -- "$_SBC_CACHE_DIR"
  rm -rf -- "$TEST_ROOT"
}
trap cleanup_test_root EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

make_release_archive() {
  local archive=$1 version=$2 platform=$3 reported_version=$4 fixture member
  fixture=$(mktemp -d "$TEST_ROOT/fixture.XXXXXX")
  member="sing-box-${version}-${platform}"
  mkdir -p "$fixture/$member"
  printf '#!/usr/bin/env bash\nprintf '\''sing-box version %s\\n'\''\n' "$reported_version" >"$fixture/$member/sing-box"
  chmod 755 "$fixture/$member/sing-box"
  tar -czf "$archive" -C "$fixture" "$member"
  rm -rf -- "$fixture"
}

curl() {
  local output="" url=""
  while (($#)); do
    case $1 in
      -o) output=$2; shift 2 ;;
      http://*|https://*) url=$1; shift ;;
      *) shift ;;
    esac
  done
  if [[ -z $output ]]; then
    printf '{"draft":false,"prerelease":false,"tag_name":"v%s"}\n' "${LATEST_VERSION:-1.13.19}"
    return 0
  fi
  printf '%s\n' "$url" >>"$CURL_LOG"
  [[ ${DOWNLOAD_FAIL:-0} != 1 ]] || return 1
  cp "$RELEASE_ARCHIVE" "$output"
}

run_bounded() {
  local timeout_seconds=$1
  shift
  printf '%s ' "$@" >>"$APK_LOG"
  printf '\n' >>"$APK_LOG"
  [[ ${APK_FAIL:-0} != 1 ]]
}

uname() { printf '%s\n' "${MOCK_MACHINE:-x86_64}"; }

[[ $(detect_sing_box_arch x86_64) == amd64 ]]
[[ $(detect_sing_box_arch aarch64) == arm64 ]]
[[ $(detect_sing_box_arch armv7l) == armv7 ]]
[[ $(detect_sing_box_arch i386) == 386 ]]
[[ $(detect_sing_box_arch i686) == 386 ]]
[[ $(detect_sing_box_arch s390x) == s390x ]]
if detect_sing_box_arch riscv64 >/dev/null 2>&1; then fail 'unsupported architecture was accepted'; fi
[[ $(sing_box_release_platform 1.13.19 amd64) == linux-amd64-musl ]]
[[ $(sing_box_release_platform 1.13.19 arm64) == linux-arm64-musl ]]
[[ $(sing_box_release_platform 1.13.19 armv7) == linux-armv7-musl ]]
[[ $(sing_box_release_platform 1.13.19 386) == linux-386-musl ]]
[[ $(sing_box_release_platform 1.13.19 s390x) == linux-s390x ]]
[[ $(sing_box_release_platform 1.12.0 amd64) == linux-amd64 ]]

# Alpine package available: no Release request and APK metadata is recorded.
(
  case_dir="$TEST_ROOT/apk-success"
  mkdir -p "$case_dir"
  META_FILE="$case_dir/meta.json"
  CERT_DIR="$case_dir/certs"
  APK_LOG="$case_dir/apk.log"
  CURL_LOG="$case_dir/curl.log"
  APK_FAIL=0
  : >"$APK_LOG"
  : >"$CURL_LOG"
  install_sing_box_alpine
  grep -Fxq 'apk add --no-cache --upgrade sing-box ' "$APK_LOG"
  [[ ! -s $CURL_LOG ]]
  [[ $(jq -r '.managedResources.singBoxInstallSource' "$META_FILE") == apk ]]
)

# Missing APK falls back to the latest stable official Release.
(
  case_dir="$TEST_ROOT/release-latest"
  mkdir -p "$case_dir/bin"
  META_FILE="$case_dir/meta.json"
  CERT_DIR="$case_dir/certs"
  SING_BOX_RELEASE_INSTALL_PATH="$case_dir/bin/sing-box"
  APK_LOG="$case_dir/apk.log"
  CURL_LOG="$case_dir/curl.log"
  RELEASE_ARCHIVE="$case_dir/release.tar.gz"
  LATEST_VERSION=1.13.19
  APK_FAIL=1
  DOWNLOAD_FAIL=0
  : >"$APK_LOG"
  : >"$CURL_LOG"
  make_release_archive "$RELEASE_ARCHIVE" 1.13.19 linux-amd64-musl 1.13.19
  install_sing_box_alpine
  [[ $($SING_BOX_RELEASE_INSTALL_PATH version) == 'sing-box version 1.13.19' ]]
  grep -Fq '/v1.13.19/sing-box-1.13.19-linux-amd64-musl.tar.gz' "$CURL_LOG"
  [[ $(jq -r '.managedResources.singBoxInstallSource' "$META_FILE") == release ]]
  [[ $(jq -r '.managedResources.singBoxBinaryPath' "$META_FILE") == "$SING_BOX_RELEASE_INSTALL_PATH" ]]
  [[ -n $(jq -r '.managedResources.singBoxBinarySHA256' "$META_FILE") ]]
)

# If Alpine later gains the APK, a still-matching managed Release binary is
# removed before switching metadata so it cannot shadow the package binary.
(
  case_dir="$TEST_ROOT/release-to-apk"
  mkdir -p "$case_dir/bin"
  META_FILE="$case_dir/meta.json"
  CERT_DIR="$case_dir/certs"
  managed_binary="$case_dir/bin/sing-box"
  APK_LOG="$case_dir/apk.log"
  CURL_LOG="$case_dir/curl.log"
  APK_FAIL=0
  : >"$APK_LOG"
  : >"$CURL_LOG"
  printf 'managed-release\n' >"$managed_binary"
  managed_sha=$(_sing_box_binary_sha256 "$managed_binary")
  _record_sing_box_install release "$managed_binary" "$managed_sha"
  install_sing_box_alpine
  [[ ! -e $managed_binary ]]
  [[ $(jq -r '.managedResources.singBoxInstallSource' "$META_FILE") == apk ]]
  [[ -z $(jq -r '.managedResources.singBoxBinaryPath // empty' "$META_FILE") ]]
)

# A user-modified Release binary is preserved instead of being silently
# reclassified as APK-managed.
(
  case_dir="$TEST_ROOT/release-to-apk-preserve"
  mkdir -p "$case_dir/bin"
  META_FILE="$case_dir/meta.json"
  CERT_DIR="$case_dir/certs"
  managed_binary="$case_dir/bin/sing-box"
  APK_LOG="$case_dir/apk.log"
  CURL_LOG="$case_dir/curl.log"
  APK_FAIL=0
  : >"$APK_LOG"
  : >"$CURL_LOG"
  printf 'managed-release\n' >"$managed_binary"
  managed_sha=$(_sing_box_binary_sha256 "$managed_binary")
  _record_sing_box_install release "$managed_binary" "$managed_sha"
  printf 'user-replacement\n' >"$managed_binary"
  if install_sing_box_alpine >/dev/null 2>&1; then fail 'modified Release binary was reclassified as APK-managed'; fi
  [[ $(<"$managed_binary") == user-replacement ]]
  [[ $(jq -r '.managedResources.singBoxInstallSource' "$META_FILE") == apk ]]
  [[ $(jq -r '.managedResources.singBoxBinaryPath' "$META_FILE") == "$managed_binary" ]]
)

# Explicit versions keep working through the Release fallback.
(
  case_dir="$TEST_ROOT/release-version"
  mkdir -p "$case_dir/bin"
  META_FILE="$case_dir/meta.json"
  CERT_DIR="$case_dir/certs"
  SING_BOX_RELEASE_INSTALL_PATH="$case_dir/bin/sing-box"
  APK_LOG="$case_dir/apk.log"
  CURL_LOG="$case_dir/curl.log"
  RELEASE_ARCHIVE="$case_dir/release.tar.gz"
  APK_FAIL=1
  DOWNLOAD_FAIL=0
  : >"$APK_LOG"
  : >"$CURL_LOG"
  make_release_archive "$RELEASE_ARCHIVE" 1.13.18 linux-amd64-musl 1.13.18
  install_sing_box_alpine v1.13.18
  grep -Fq '/v1.13.18/sing-box-1.13.18-linux-amd64-musl.tar.gz' "$CURL_LOG"
  [[ $($SING_BOX_RELEASE_INSTALL_PATH version) == 'sing-box version 1.13.18' ]]
)

# Download failure must leave an existing core byte-for-byte intact.
(
  case_dir="$TEST_ROOT/download-failure"
  mkdir -p "$case_dir/bin"
  META_FILE="$case_dir/meta.json"
  CERT_DIR="$case_dir/certs"
  SING_BOX_RELEASE_INSTALL_PATH="$case_dir/bin/sing-box"
  APK_LOG="$case_dir/apk.log"
  CURL_LOG="$case_dir/curl.log"
  RELEASE_ARCHIVE="$case_dir/missing.tar.gz"
  APK_FAIL=1
  DOWNLOAD_FAIL=1
  printf 'old-core-download\n' >"$SING_BOX_RELEASE_INSTALL_PATH"
  before=$(openssl dgst -sha256 "$SING_BOX_RELEASE_INSTALL_PATH" | awk '{print $NF}')
  if install_sing_box_alpine 1.13.18 >/dev/null 2>&1; then fail 'download failure unexpectedly succeeded'; fi
  after=$(openssl dgst -sha256 "$SING_BOX_RELEASE_INSTALL_PATH" | awk '{print $NF}')
  [[ $before == "$after" ]]
)

# Invalid/unsupported binaries are rejected before replacing an old core.
(
  case_dir="$TEST_ROOT/validation-failure"
  mkdir -p "$case_dir/bin"
  META_FILE="$case_dir/meta.json"
  CERT_DIR="$case_dir/certs"
  SING_BOX_RELEASE_INSTALL_PATH="$case_dir/bin/sing-box"
  APK_LOG="$case_dir/apk.log"
  CURL_LOG="$case_dir/curl.log"
  RELEASE_ARCHIVE="$case_dir/release.tar.gz"
  APK_FAIL=1
  DOWNLOAD_FAIL=0
  printf 'old-core-validation\n' >"$SING_BOX_RELEASE_INSTALL_PATH"
  before=$(openssl dgst -sha256 "$SING_BOX_RELEASE_INSTALL_PATH" | awk '{print $NF}')
  make_release_archive "$RELEASE_ARCHIVE" 1.13.18 linux-amd64-musl 1.11.0
  if install_sing_box_alpine 1.13.18 >/dev/null 2>&1; then fail 'invalid binary unexpectedly succeeded'; fi
  after=$(openssl dgst -sha256 "$SING_BOX_RELEASE_INSTALL_PATH" | awk '{print $NF}')
  [[ $before == "$after" ]]
)

# APK-managed installations uninstall through apk del.
(
  case_dir="$TEST_ROOT/uninstall-apk"
  mkdir -p "$case_dir"
  META_FILE="$case_dir/meta.json"
  CERT_DIR="$case_dir/certs"
  apk_log="$case_dir/apk.log"
  _record_sing_box_install apk
  apk() { printf '%s ' "$@" >>"$apk_log"; printf '\n' >>"$apk_log"; }
  service_stop() { :; }
  service_disable() { :; }
  _remove_sbctl_service_definition() { :; }
  _remove_sing_box_core
  grep -Fxq 'del sing-box ' "$apk_log"
  [[ -z $(jq -r '.managedResources.singBoxInstallSource // empty' "$META_FILE") ]]
)

# Release-managed installations are removed only while path and SHA match.
(
  case_dir="$TEST_ROOT/uninstall-release"
  mkdir -p "$case_dir/bin"
  META_FILE="$case_dir/meta.json"
  CERT_DIR="$case_dir/certs"
  managed_binary="$case_dir/bin/sing-box"
  printf 'managed-release\n' >"$managed_binary"
  managed_sha=$(_sing_box_binary_sha256 "$managed_binary")
  _record_sing_box_install release "$managed_binary" "$managed_sha"
  service_stop() { :; }
  service_disable() { :; }
  _remove_sbctl_service_definition() { :; }
  _remove_sing_box_core
  [[ ! -e $managed_binary ]]
)

# A user-replaced binary at the recorded path must be preserved.
(
  case_dir="$TEST_ROOT/uninstall-preserve-user"
  mkdir -p "$case_dir/bin"
  META_FILE="$case_dir/meta.json"
  CERT_DIR="$case_dir/certs"
  managed_binary="$case_dir/bin/sing-box"
  printf 'managed-release\n' >"$managed_binary"
  managed_sha=$(_sing_box_binary_sha256 "$managed_binary")
  _record_sing_box_install release "$managed_binary" "$managed_sha"
  printf 'user-replacement\n' >"$managed_binary"
  service_stop() { :; }
  service_disable() { :; }
  _remove_sbctl_service_definition() { :; }
  if _remove_sing_box_core >/dev/null 2>&1; then fail 'user-replaced binary was accepted as managed'; fi
  [[ $(<"$managed_binary") == user-replacement ]]
)

# Debian/Ubuntu still uses the existing official installer path.
(
  case_dir="$TEST_ROOT/debian"
  mkdir -p "$case_dir/bin"
  CONFIG_FILE="$case_dir/config.json"
  META_FILE="$case_dir/meta.json"
  CERT_DIR="$case_dir/certs"
  SING_BOX_BIN="$case_dir/bin/sing-box"
  SBCTL_SING_BOX_BIN="$SING_BOX_BIN"
  DEBIAN_INSTALL_LOG="$case_dir/installer.log"
  export DEBIAN_INSTALL_LOG
  printf '#!/usr/bin/env bash\nprintf '\''sing-box version 1.13.18\\n'\''\n' >"$SING_BOX_BIN"
  chmod 755 "$SING_BOX_BIN"
  ensure_dependencies() { :; }
  pkg_manager() { printf 'apt'; }
  curl() {
    local output=""
    while (($#)); do
      if [[ $1 == -o ]]; then output=$2; shift 2; else shift; fi
    done
    printf '#!/usr/bin/env bash\nprintf '\''%%s\\n'\'' "$*" >"$DEBIAN_INSTALL_LOG"\n' >"$output"
  }
  run_bounded() { local timeout_seconds=$1; shift; "$@"; }
  refresh_binary_path() { :; }
  sing_box_installed() { return 0; }
  require_supported_core() { :; }
  write_default_config() { :; }
  ensure_config() { :; }
  create_service_definition() { :; }
  install_quick_command() { :; }
  validate_candidate() { :; }
  service_enable() { :; }
  service_is_active() { return 1; }
  service_start() { :; }
  service_restart() { :; }
  install_or_update_sing_box 1.13.18 >/dev/null
  [[ $(<"$DEBIAN_INSTALL_LOG") == '--version 1.13.18' ]]
)

printf 'sing-box Alpine install/uninstall tests passed.\n'
