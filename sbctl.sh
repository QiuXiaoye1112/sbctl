#!/usr/bin/env bash
# sbctl - sing-box Linux terminal manager
# Inspired by xrayctl's interaction model, implemented for sing-box.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SBCTL_VERSION="0.2.6"
readonly PROJECT_REPO="QiuXiaoye1112/sbctl"
readonly SCRIPT_DOWNLOAD_URL="${SBCTL_SCRIPT_URL:-https://raw.githubusercontent.com/${PROJECT_REPO}/main/sbctl.sh}"
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
CERT_STOPPED_SERVICE=0

SBCTL_ENTRYPOINT="${SBCTL_ENTRYPOINT:-$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")}"
_repo_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib"
if [[ -n ${SBCTL_LIB_DIR:-} ]]; then
  LIB_DIR=$SBCTL_LIB_DIR
elif [[ -d $_repo_lib ]]; then
  LIB_DIR=$_repo_lib
else
  LIB_DIR=/usr/local/lib/sbctl
fi
unset _repo_lib

for _module in core ui engine compat inbound outbound clients ops management menu layout system_ext; do
  [[ -r "$LIB_DIR/${_module}.sh" ]] || { printf '[错误] 缺少 sbctl 模块: %s\n' "$LIB_DIR/${_module}.sh" >&2; exit 1; }
  # shellcheck disable=SC1090
  source "$LIB_DIR/${_module}.sh"
done
unset _module

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then dispatch "$@"; fi
