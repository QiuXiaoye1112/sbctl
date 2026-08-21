#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sbctl-sing-box-lifecycle.XXXXXX")
export SBCTL_TESTING=1
export SBCTL_CONFIG_DIR="$TEST_ROOT/default/config"
export SBCTL_CONFIG_FILE="$SBCTL_CONFIG_DIR/config.json"
export SBCTL_META_FILE="$TEST_ROOT/default/meta.json"
export SBCTL_CERT_DIR="$SBCTL_CONFIG_DIR/certs"
export SBCTL_LOCK_FILE="$TEST_ROOT/default/lock"
export SBCTL_SYSTEMD_UNIT_DIR="$TEST_ROOT/default/systemd"
export SBCTL_OPENRC_INIT_DIR="$TEST_ROOT/default/openrc"
export SBCTL_SING_BOX_RELEASE_INSTALL_PATH="$TEST_ROOT/default/bin/sing-box"
source ./sbctl.sh
trap - ERR

cleanup_test_root() {
  [[ -z ${_SBC_CACHE_DIR:-} || ! -d ${_SBC_CACHE_DIR:-} ]] || rm -rf -- "$_SBC_CACHE_DIR"
  rm -rf -- "$TEST_ROOT"
}
trap cleanup_test_root EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

make_release_archive() {
  local archive=$1 version=$2 platform=$3 reported_version=$4 check_result=${5:-ok} fixture member check_exit=0
  [[ $check_result == ok ]] || check_exit=1
  fixture=$(mktemp -d "$TEST_ROOT/fixture.XXXXXX")
  member="sing-box-${version}-${platform}"
  mkdir -p "$fixture/$member"
  cat >"$fixture/$member/sing-box" <<EOF_BINARY
#!/usr/bin/env bash
case \${1-} in
  version) printf 'sing-box version ${reported_version}\\n' ;;
  check) exit ${check_exit} ;;
  *) exit 1 ;;
esac
EOF_BINARY
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
  case ${DOWNLOAD_MODE:-ok} in
    ok) cp "$RELEASE_ARCHIVE" "$output" ;;
    corrupt) printf 'not-a-tarball\n' >"$output" ;;
    fail) return 1 ;;
    404) return 22 ;;
    *) return 1 ;;
  esac
}

uname() { printf '%s\n' "${MOCK_MACHINE:-x86_64}"; }

prepare_case() {
  local name=$1 case_dir
  case_dir="$TEST_ROOT/$name"
  mkdir -p "$case_dir/bin"
  CONFIG_DIR="$case_dir/config"
  CONFIG_FILE="$CONFIG_DIR/config.json"
  META_FILE="$case_dir/meta.json"
  CERT_DIR="$CONFIG_DIR/certs"
  LOCK_FILE="$case_dir/lock"
  SYSTEMD_UNIT_DIR="$case_dir/systemd"
  OPENRC_INIT_DIR="$case_dir/openrc"
  DATA_DIR="$case_dir/data"
  QUICK_COMMAND="$case_dir/sbin/sbctl"
  QUICK_SYMLINK="$case_dir/bin/sbctl-link"
  SING_BOX_RELEASE_INSTALL_PATH="$case_dir/bin/sing-box"
  SING_BOX_BIN=$SING_BOX_RELEASE_INSTALL_PATH
  SBCTL_SING_BOX_BIN=""
  CURL_LOG="$case_dir/curl.log"
  RELEASE_ARCHIVE="$case_dir/release.tar.gz"
  DOWNLOAD_MODE=ok
  LATEST_VERSION=1.13.19
  MOCK_MACHINE=x86_64
  : >"$CURL_LOG"
  sbc_invalidate_install_cache
  find_external_sing_box() { :; }
}

mock_successful_service() {
  SERVICE_PRESENT=${SERVICE_PRESENT:-0}
  SERVICE_ACTIVE=${SERVICE_ACTIVE:-0}
  service_exists() { ((SERVICE_PRESENT == 1)); }
  service_is_active() { ((SERVICE_ACTIVE == 1)); }
  service_enable() { :; }
  service_start() { SERVICE_PRESENT=1; SERVICE_ACTIVE=1; }
  service_restart() { SERVICE_ACTIVE=1; }
  service_stop() { SERVICE_ACTIVE=0; }
  service_disable() { :; }
  create_service_definition() { SERVICE_PRESENT=1; }
  install_quick_command() { :; }
  _remove_sbctl_service_definition() { SERVICE_PRESENT=0; }
}

make_managed_core() {
  local version=$1 arch=${2:-amd64} sha
  mkdir -p "${SING_BOX_RELEASE_INSTALL_PATH%/*}"
  cat >"$SING_BOX_RELEASE_INSTALL_PATH" <<EOF_BINARY
#!/usr/bin/env bash
case \${1-} in
  version) printf 'sing-box version ${version}\\n' ;;
  check) exit 0 ;;
  *) exit 1 ;;
esac
EOF_BINARY
  chmod 755 "$SING_BOX_RELEASE_INSTALL_PATH"
  sha=$(_sing_box_binary_sha256 "$SING_BOX_RELEASE_INSTALL_PATH")
  _record_sing_box_install "$version" "$arch" "$sha" "linux-${arch}-musl"
}

[[ $(detect_sing_box_arch x86_64) == amd64 ]]
[[ $(detect_sing_box_arch amd64) == amd64 ]]
[[ $(detect_sing_box_arch aarch64) == arm64 ]]
[[ $(detect_sing_box_arch arm64) == arm64 ]]
[[ $(detect_sing_box_arch armv7l) == armv7 ]]
[[ $(detect_sing_box_arch armv6l) == armv6 ]]
for machine in i386 i486 i586 i686; do [[ $(detect_sing_box_arch "$machine") == 386 ]]; done
[[ $(detect_sing_box_arch s390x) == s390x ]]
[[ $(detect_sing_box_arch riscv64) == riscv64 ]]
if detect_sing_box_arch mips64 >/dev/null 2>&1; then fail 'unsupported architecture was accepted'; fi
[[ $(sing_box_release_platform 1.13.19 amd64) == linux-amd64-musl ]]
[[ $(sing_box_release_platform 1.13.19 arm64) == linux-arm64-musl ]]
[[ $(sing_box_release_platform 1.13.19 riscv64) == linux-riscv64-musl ]]
[[ $(sing_box_release_platform 1.13.19 armv6) == linux-armv6 ]]
[[ $(sing_box_release_platform 1.13.19 s390x) == linux-s390x ]]

LATEST_VERSION=1.13.19
[[ $(resolve_sing_box_version) == 1.13.19 ]]
[[ $(resolve_sing_box_version 1.13.18) == 1.13.18 ]]
[[ $(resolve_sing_box_version v1.13.18) == 1.13.18 ]]

for mode in fail 404; do
  (
    prepare_case "download-$mode"
    DOWNLOAD_MODE=$mode
    mock_successful_service
    if install_sing_box_release 1.13.19 >/dev/null 2>&1; then fail "$mode download unexpectedly succeeded"; fi
    [[ ! -e $SING_BOX_RELEASE_INSTALL_PATH ]]
  )
done

(
  prepare_case update-download-failure
  make_managed_core 1.13.18
  before=$(_sing_box_binary_sha256 "$SING_BOX_RELEASE_INSTALL_PATH")
  DOWNLOAD_MODE=fail
  SERVICE_PRESENT=1 SERVICE_ACTIVE=1
  mock_successful_service
  if install_sing_box_release 1.13.19 >/dev/null 2>&1; then fail 'failed update download unexpectedly succeeded'; fi
  after=$(_sing_box_binary_sha256 "$SING_BOX_RELEASE_INSTALL_PATH")
  [[ $before == "$after" ]]
  [[ $(jq -r '.singBox.version' "$META_FILE") == 1.13.18 ]]
)

(
  prepare_case corrupt-tar
  DOWNLOAD_MODE=corrupt
  mock_successful_service
  if install_sing_box_release 1.13.19 >/dev/null 2>&1; then fail 'corrupt tar unexpectedly succeeded'; fi
  [[ ! -e $SING_BOX_RELEASE_INSTALL_PATH ]]
)

(
  prepare_case wrong-version
  make_release_archive "$RELEASE_ARCHIVE" 1.13.19 linux-amd64-musl 1.13.18
  mock_successful_service
  if install_sing_box_release 1.13.19 >/dev/null 2>&1; then fail 'wrong binary version unexpectedly succeeded'; fi
  [[ ! -e $SING_BOX_RELEASE_INSTALL_PATH ]]
)

(
  prepare_case fresh-install
  make_release_archive "$RELEASE_ARCHIVE" 1.13.19 linux-amd64-musl 1.13.19
  mock_successful_service
  install_sing_box_release
  [[ $($SING_BOX_RELEASE_INSTALL_PATH version) == 'sing-box version 1.13.19' ]]
  jq -e --arg binary "$SING_BOX_RELEASE_INSTALL_PATH" '
    .singBox.managed==true and .singBox.source=="official-release" and
    .singBox.version=="1.13.19" and .singBox.arch=="amd64" and .singBox.binary==$binary
  ' "$META_FILE" >/dev/null
  [[ $SERVICE_ACTIVE == 1 ]]
)

(
  prepare_case normal-update
  make_managed_core 1.13.18
  make_release_archive "$RELEASE_ARCHIVE" 1.13.19 linux-amd64-musl 1.13.19
  SERVICE_PRESENT=1 SERVICE_ACTIVE=1
  mock_successful_service
  install_sing_box_release 1.13.19
  [[ $($SING_BOX_RELEASE_INSTALL_PATH version) == 'sing-box version 1.13.19' ]]
  [[ $(jq -r '.singBox.version' "$META_FILE") == 1.13.19 ]]
)

(
  prepare_case config-rejected
  make_managed_core 1.13.18
  write_default_config
  make_release_archive "$RELEASE_ARCHIVE" 1.13.19 linux-amd64-musl 1.13.19 fail
  SERVICE_PRESENT=1 SERVICE_ACTIVE=1
  mock_successful_service
  if install_sing_box_release 1.13.19 >/dev/null 2>&1; then fail 'config-rejected update unexpectedly succeeded'; fi
  [[ $($SING_BOX_RELEASE_INSTALL_PATH version) == 'sing-box version 1.13.18' ]]
)

(
  prepare_case service-rollback
  make_managed_core 1.13.18
  write_default_config
  make_release_archive "$RELEASE_ARCHIVE" 1.13.19 linux-amd64-musl 1.13.19
  SERVICE_PRESENT=1 SERVICE_ACTIVE=1 RESTART_CALLS=0
  mock_successful_service
  service_restart() {
    ((RESTART_CALLS+=1))
    if ((RESTART_CALLS == 1)); then SERVICE_ACTIVE=0; return 1; fi
    SERVICE_ACTIVE=1
  }
  if install_sing_box_release 1.13.19 >/dev/null 2>&1; then fail 'failed service restart unexpectedly succeeded'; fi
  [[ $($SING_BOX_RELEASE_INSTALL_PATH version) == 'sing-box version 1.13.18' ]]
  [[ $(jq -r '.singBox.version' "$META_FILE") == 1.13.18 ]]
  [[ $SERVICE_ACTIVE == 1 ]]
)

(
  prepare_case fresh-service-failure
  make_release_archive "$RELEASE_ARCHIVE" 1.13.19 linux-amd64-musl 1.13.19
  SERVICE_PRESENT=0 SERVICE_ACTIVE=0
  mock_successful_service
  service_start() { return 1; }
  if install_sing_box_release 1.13.19 >/dev/null 2>&1; then fail 'failed fresh service start unexpectedly succeeded'; fi
  [[ ! -e $SING_BOX_RELEASE_INSTALL_PATH ]]
  [[ ! -f $META_FILE || -z $(jq -r '.singBox // empty' "$META_FILE") ]]
)

(
  prepare_case external-target
  printf 'external-core\n' >"$SING_BOX_RELEASE_INSTALL_PATH"
  chmod 755 "$SING_BOX_RELEASE_INSTALL_PATH"
  make_release_archive "$RELEASE_ARCHIVE" 1.13.19 linux-amd64-musl 1.13.19
  mock_successful_service
  if install_sing_box_release 1.13.19 >/dev/null 2>&1; then fail 'external target was overwritten'; fi
  [[ $(<"$SING_BOX_RELEASE_INSTALL_PATH") == external-core ]]
)
(
  prepare_case external-path
  find_external_sing_box() { printf '/usr/bin/sing-box\n'; }
  make_release_archive "$RELEASE_ARCHIVE" 1.13.19 linux-amd64-musl 1.13.19
  mock_successful_service
  if install_sing_box_release 1.13.19 >/dev/null 2>&1; then fail 'external PATH binary was shadowed'; fi
  [[ ! -e $SING_BOX_RELEASE_INSTALL_PATH ]]
)

(
  prepare_case external-uninstall
  printf 'external-core\n' >"$SING_BOX_RELEASE_INSTALL_PATH"
  chmod 755 "$SING_BOX_RELEASE_INSTALL_PATH"
  service_stop() { :; }; service_disable() { :; }
  _sbctl_service_definition_is_managed() { return 1; }
  _remove_sing_box_core
  [[ -e $SING_BOX_RELEASE_INSTALL_PATH ]]
)
(
  prepare_case legacy-package-uninstall
  printf 'package-core\n' >"$SING_BOX_RELEASE_INSTALL_PATH"
  chmod 755 "$SING_BOX_RELEASE_INSTALL_PATH"
  init_meta
  tmp=$(temp_file)
  jq '.managedResources.singBoxInstallSource="apk"' "$META_FILE" >"$tmp"
  install -m 600 "$tmp" "$META_FILE"; rm -f "$tmp"
  service_stop() { :; }; service_disable() { :; }
  _sbctl_service_definition_is_managed() { return 1; }
  _remove_sing_box_core
  [[ -e $SING_BOX_RELEASE_INSTALL_PATH ]]
)
(
  prepare_case managed-uninstall
  make_managed_core 1.13.18
  service_stop() { :; }; service_disable() { :; }
  _remove_sbctl_service_definition() { :; }
  _remove_sing_box_core
  [[ ! -e $SING_BOX_RELEASE_INSTALL_PATH ]]
  [[ -z $(jq -r '.singBox // empty' "$META_FILE") ]]
)

(
  prepare_case systemd-service
  init_system() { printf systemd; }
  systemctl() { :; }
  create_service_definition
  grep -Fq "ExecStart=${SING_BOX_RELEASE_INSTALL_PATH} run" "$SYSTEMD_UNIT_DIR/$SERVICE_NAME.service"
)
(
  prepare_case openrc-service
  init_system() { printf openrc; }
  create_service_definition
  grep -Fq "command=\"${SING_BOX_RELEASE_INSTALL_PATH}\"" "$OPENRC_INIT_DIR/$SERVICE_NAME"
)

! rg -n 'apk (add|del).*sing-box|apt(-get)? .*sing-box|dnf .*sing-box|yum .*sing-box|pacman .*sing-box|zypper .*sing-box' \
  src/service.sh src/uninstall.sh

printf 'sing-box official Release lifecycle tests passed.\n'
