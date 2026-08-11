#!/usr/bin/env bash
# sbctl - sing-box Linux terminal manager
# Inspired by xrayctl's interaction model, implemented for sing-box.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SBCTL_VERSION="0.4.0"
readonly PROJECT_REPO="QiuXiaoye1112/sbctl"
readonly SCRIPT_DOWNLOAD_URL="${SBCTL_SCRIPT_URL:-https://github.com/${PROJECT_REPO}/raw/refs/heads/main/sbctl.sh}"
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
SYSTEMD_UNIT_DIR="${SBCTL_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
OPENRC_INIT_DIR="${SBCTL_OPENRC_INIT_DIR:-/etc/init.d}"
CERTBOT_HOOK_DIR="${SBCTL_CERTBOT_HOOK_DIR:-/etc/letsencrypt/renewal-hooks/deploy}"
CERTBOT_VENV="${SBCTL_CERTBOT_VENV:-/opt/sbctl/certbot}"
CERTBOT_BIN="${SBCTL_CERTBOT_BIN:-${CERTBOT_VENV}/bin/certbot}"
CERTBOT_CONFIG_DIR="${SBCTL_CERTBOT_CONFIG_DIR:-/var/lib/sbctl/letsencrypt}"
CERTBOT_WORK_DIR="${SBCTL_CERTBOT_WORK_DIR:-/var/lib/sbctl/certbot-work}"
CERTBOT_LOGS_DIR="${SBCTL_CERTBOT_LOGS_DIR:-/var/log/sbctl/certbot}"
CERT_STOPPED_SERVICE=0
APT_IPV4_AVAILABLE_CACHE=""

if [[ -z ${SBCTL_ENTRYPOINT:-} ]]; then
  SBCTL_ENTRYPOINT=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
fi
_repo_src="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/src"
SRC_DIR="${SBCTL_SRC_DIR:-$_repo_src}"
LIB_DIR="${SBCTL_LIB_DIR:-/usr/local/lib/sbctl}"
unset _repo_src

# Centralized dependency order. Source modules never source one another.
for _module in \
  platform core ui platform_network \
  state_migrations state \
  certificate/metadata certificate/core security \
  outbound inbound/core inbound/clients share state_backup \
  certificate/lifecycle certificate/cloudflare certificate/environment \
  hysteria2 hysteria2_network protocols service management menu uninstall
do
  [[ -r "$SRC_DIR/${_module}.sh" ]] || { printf '[错误] 缺少 sbctl 模块: %s\n' "$SRC_DIR/${_module}.sh" >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$SRC_DIR/${_module}.sh"
done
unset _module

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then dispatch "$@"; fi
