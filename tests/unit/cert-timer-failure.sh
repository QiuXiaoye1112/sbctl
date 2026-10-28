#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export SBCTL_TESTING=1
source "$ROOT/sbctl.sh"
SYSTEMD_UNIT_DIR=$TMP
QUICK_COMMAND=/bin/true
init_system() { echo systemd; }
meta_resource_register() { :; }
systemctl() { [[ $1 != enable ]]; }
if setup_certbot_renewal_timer; then echo 'timer failure was ignored' >&2; exit 1; fi
systemctl() { [[ $1 != daemon-reload ]]; }
if setup_certbot_renewal_timer; then echo 'daemon-reload failure was ignored' >&2; exit 1; fi
TRAFFIC_SYSTEMD_SERVICE=$TMP/traffic-install.service
TRAFFIC_SYSTEMD_TIMER=$TMP/traffic-install.timer
TRAFFIC_FILE=$TMP/traffic.json
TRAFFIC_LOCK=$TMP/traffic.lock
if traffic_timer_install; then echo 'traffic daemon-reload failure was ignored' >&2; exit 1; fi
systemctl() { return 0; }
meta_resource_register() { return 1; }
if traffic_timer_install; then echo 'traffic registration failure was ignored' >&2; exit 1; fi
meta_resource_register() { :; }
systemctl() { [[ $1 != disable ]]; }
meta_cert_auto_renew_certs() { :; }
if _disable_renewal_job_if_unused; then echo 'unused renewal timer stop failure was ignored' >&2; exit 1; fi
if _remove_renewal_jobs; then echo 'renewal timer stop failure was ignored' >&2; exit 1; fi
[[ -f $TMP/sbctl-certbot-renew.timer && -f $TMP/sbctl-certbot-renew.service ]]
systemctl() { return 0; }
_remove_renewal_jobs
_remove_renewal_jobs
[[ ! -e $TMP/sbctl-certbot-renew.timer && ! -e $TMP/sbctl-certbot-renew.service ]]
TRAFFIC_SYSTEMD_TIMER=$TMP/traffic.timer
TRAFFIC_SYSTEMD_SERVICE=$TMP/traffic.service
touch "$TRAFFIC_SYSTEMD_TIMER" "$TRAFFIC_SYSTEMD_SERVICE"
systemctl() { [[ $1 != stop ]]; }
traffic_rules_clear() { touch "$TMP/rules-cleared"; }
if traffic_runtime_stop; then echo 'traffic service stop failure was ignored' >&2; exit 1; fi
[[ -f $TRAFFIC_SYSTEMD_SERVICE && ! -e $TMP/rules-cleared ]]
systemctl() { return 0; }
traffic_runtime_stop
[[ -e $TMP/rules-cleared && ! -e $TRAFFIC_SYSTEMD_SERVICE ]]
(
  ensure_dependencies() { :; }
  meta_cert_exists() { :; }
  certificate_inbound_users() { :; }
  meta_cert_get_field() { :; }
  meta_cert_delete() { touch "$TMP/metadata-deleted"; }
  rm() { return 1; }
  if delete_certificate example 1; then echo 'certificate file deletion failure was ignored' >&2; exit 1; fi
  [[ ! -e $TMP/metadata-deleted ]]
)
(
  ensure_dependencies() { :; }
  meta_cert_exists() { [[ ! -e $TMP/metadata-deleted-retry ]]; }
  certificate_inbound_users() { :; }
  meta_cert_get_field() { :; }
  meta_cert_auto_renew_certs() { printf '%s\n' example; }
  meta_cert_delete() { touch "$TMP/metadata-deleted-retry"; }
  CERT_DIR=$TMP/certs; CERTBOT_HOOK_DIR=$TMP/hooks
  mkdir -p "$CERT_DIR" "$CERTBOT_HOOK_DIR"
  touch "$SYSTEMD_UNIT_DIR/sbctl-certbot-renew.timer"
  systemctl() { [[ $1 != disable ]]; }
  if delete_certificate example 1; then echo 'cleanup failure was ignored' >&2; exit 1; fi
  [[ ! -e $TMP/metadata-deleted-retry ]]
  systemctl() { return 0; }
  delete_certificate example 1
  [[ -e $TMP/metadata-deleted-retry ]]
  touch "$SYSTEMD_UNIT_DIR/sbctl-certbot-renew.timer"
  meta_cert_auto_renew_certs() { printf "%s\n" example other; }
  _disable_renewal_job_if_unused example
  [[ -e $SYSTEMD_UNIT_DIR/sbctl-certbot-renew.timer ]]
  meta_cert_auto_renew_certs() { return 1; }
  if _disable_renewal_job_if_unused example; then echo "metadata read failure was ignored" >&2; exit 1; fi
  [[ -e $SYSTEMD_UNIT_DIR/sbctl-certbot-renew.timer ]]
)
echo 'certificate timer failure tests passed' 
