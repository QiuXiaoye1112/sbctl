#!/usr/bin/env bash
# sbctl - sing-box Linux terminal manager
# Inspired by xrayctl's interaction model, implemented for sing-box.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SBCTL_VERSION="0.4.2"
readonly SBCTL_BUILD_COMMIT="${SBCTL_BUILD_COMMIT:-development}"
readonly PROJECT_REPO="QiuXiaoye1112/sbctl"
readonly SCRIPT_DOWNLOAD_URL="${SBCTL_SCRIPT_URL:-https://github.com/${PROJECT_REPO}/raw/refs/heads/main/dist/sbctl}"
readonly OFFICIAL_INSTALLER_URL="https://sing-box.app/install.sh"

SING_BOX_BIN="${SBCTL_SING_BOX_BIN:-$(command -v sing-box 2>/dev/null || printf /usr/local/bin/sing-box)}"
CONFIG_DIR="${SBCTL_CONFIG_DIR:-/etc/sing-box}"
CONFIG_FILE="${SBCTL_CONFIG_FILE:-${CONFIG_DIR}/config.json}"
META_FILE="${SBCTL_META_FILE:-/var/lib/sbctl/meta.json}"
CERT_DIR="${SBCTL_CERT_DIR:-${CONFIG_DIR}/certs}"
BACKUP_DIR="${SBCTL_BACKUP_DIR:-/var/backups/sbctl}"
QUICK_COMMAND="${SBCTL_COMMAND_PATH:-/usr/local/sbin/sbctl}"
QUICK_SYMLINK="${SBCTL_SYMLINK_PATH:-/usr/local/bin/sbctl}"
SERVICE_NAME="${SBCTL_SERVICE_NAME:-sing-box}"
LOCK_FILE="${SBCTL_LOCK_FILE:-/run/lock/sbctl.lock}"
DATA_DIR="${SBCTL_DATA_DIR:-/var/lib/sing-box}"
XRAYCTL_CONFIG_FILE="${SBCTL_XRAYCTL_CONFIG_FILE:-/usr/local/etc/xray/config.json}"
SBCTL_BBR_CONFIG="${SBCTL_BBR_CONFIG:-/etc/sysctl.d/99-sbctl-bbr.conf}"
XRAYCTL_BBR_CONFIG="${SBCTL_XRAYCTL_BBR_CONFIG:-/etc/sysctl.d/99-xrayctl-bbr.conf}"
SYSTEMD_UNIT_DIR="${SBCTL_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
OPENRC_INIT_DIR="${SBCTL_OPENRC_INIT_DIR:-/etc/init.d}"
CERTBOT_HOOK_DIR="${SBCTL_CERTBOT_HOOK_DIR:-/etc/letsencrypt/renewal-hooks/deploy}"
CERTBOT_VENV="${SBCTL_CERTBOT_VENV:-/opt/sbctl/certbot}"
CERTBOT_BIN="${SBCTL_CERTBOT_BIN:-${CERTBOT_VENV}/bin/certbot}"
CERTBOT_CONFIG_DIR="${SBCTL_CERTBOT_CONFIG_DIR:-/var/lib/sbctl/letsencrypt}"
CERTBOT_WORK_DIR="${SBCTL_CERTBOT_WORK_DIR:-/var/lib/sbctl/certbot-work}"
CERTBOT_LOGS_DIR="${SBCTL_CERTBOT_LOGS_DIR:-/var/log/sbctl/certbot}"
_default_certbot_shared_lock=/run/lock/xrayctl-sbctl-certbot.lock
if [[ ${SBCTL_TESTING:-0} == 1 ]]; then _default_certbot_shared_lock="${LOCK_FILE%/*}/xrayctl-sbctl-certbot.lock"; fi
CERTBOT_SHARED_LOCK="${SBCTL_CERTBOT_SHARED_LOCK:-$_default_certbot_shared_lock}"
unset _default_certbot_shared_lock
CERTBOT_SHARED_LOCK_WAIT="${SBCTL_CERTBOT_SHARED_LOCK_WAIT:-300}"
CERT_STOPPED_SERVICE=0
APT_IPV4_AVAILABLE_CACHE=""

if [[ -z ${SBCTL_ENTRYPOINT:-} ]]; then
  SBCTL_ENTRYPOINT=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
fi
LIB_DIR="${SBCTL_LIB_DIR:-/usr/local/lib/sbctl}"

# BEGIN MODULE LOADER
_repo_src="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/src"
SRC_DIR="${SBCTL_SRC_DIR:-$_repo_src}"
unset _repo_src

# Centralized dependency order. Source modules never source one another.
SBCTL_MODULES=(
  "core"
  "platform"
  "state"
  "certificate/core"
  "security"
  "protocols"
  "hysteria2"
  "inbound"
  "inbound/clients"
  "outbound"
  "share"
  "certificate/lifecycle"
  "certificate/cloudflare"
  "certificate/certbot"
  "service"
  "uninstall"
  "menu"
)
for _module in "${SBCTL_MODULES[@]}"; do
  [[ -r "$SRC_DIR/${_module}.sh" ]] || { printf '[错误] 缺少 sbctl 模块: %s\n' "$SRC_DIR/${_module}.sh" >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$SRC_DIR/${_module}.sh"
done
unset _module SBCTL_MODULES
# END MODULE LOADER

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then dispatch "$@"; fi
