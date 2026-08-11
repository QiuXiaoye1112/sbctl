#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

bash -n src/certificate/cloudflare.sh
bash -n src/certificate/certbot.sh

! grep -Fq "'cloudflare<3'" src/certificate/cloudflare.sh
! grep -Fq -- '--no-deps' src/certificate/cloudflare.sh
grep -Fq 'certbot-dns-cloudflare==${certbot_version}' src/certificate/cloudflare.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CASE="$TMP/case"
mkdir -p "$CASE/cfg" "$CASE/certs" "$CASE/bin"

SBCTL_TESTING=1 \
SBCTL_CONFIG_DIR="$CASE/cfg" \
SBCTL_CONFIG_FILE="$CASE/cfg/config.json" \
SBCTL_META_FILE="$CASE/meta.json" \
SBCTL_CERT_DIR="$CASE/certs" \
SBCTL_BACKUP_DIR="$CASE/backups" \
SBCTL_DATA_DIR="$CASE/data" \
SBCTL_COMMAND_PATH="$CASE/bin/sbctl" \
SBCTL_SYMLINK_PATH="$CASE/bin/sbctl-link" \
SBCTL_LOCK_FILE="$CASE/lock" \
SBCTL_CERTBOT_VENV="$CASE/certbot-venv" \
SBCTL_CERTBOT_CONFIG_DIR="$CASE/certbot-config" \
SBCTL_CERTBOT_WORK_DIR="$CASE/certbot-work" \
SBCTL_CERTBOT_LOGS_DIR="$CASE/certbot-logs" \
SBCTL_CLOUDFLARE_INI="$CASE/cloudflare.ini" \
CF_TEST_CASE="$CASE" \
bash <<'SH'
set -Eeuo pipefail
source ./sbctl.sh

init_meta
write_default_config

save_cloudflare_credentials 'cf@example.com' 'global-api-key-test'
load_cloudflare_credentials
mode=$(stat -c '%a' "$CLOUDFLARE_INI" 2>/dev/null || stat -f '%Lp' "$CLOUDFLARE_INI")
[[ $mode == 600 ]]
grep -Fq 'dns_cloudflare_email = cf@example.com' "$CLOUDFLARE_INI"
grep -Fq 'dns_cloudflare_api_key = global-api-key-test' "$CLOUDFLARE_INI"
! grep -Fq 'dns_cloudflare_api_token' "$CLOUDFLARE_INI"
[[ $(meta_resource_get cloudflareCredentials) == "$CLOUDFLARE_INI" ]]

# Do not access the network: verify the exact Certbot plugin invocation surface.
CF_ARGS="$CF_TEST_CASE/certbot-args"
ensure_cloudflare_certbot_plugin() { return 0; }
certbot_cmd() { printf '%s\n' "$@" >"$CF_ARGS"; }
_issue_domain_cloudflare example.com le@example.com 0
grep -Fxq -- '--dns-cloudflare' "$CF_ARGS"
grep -Fxq -- '--dns-cloudflare-credentials' "$CF_ARGS"
grep -Fxq -- "$CLOUDFLARE_INI" "$CF_ARGS"
grep -Fxq -- '--dns-cloudflare-propagation-seconds' "$CF_ARGS"
grep -Fxq -- '10' "$CF_ARGS"

meta_cert_set cf-cert example.com example.com letsencrypt dns-cloudflare true
[[ $(cloudflare_dependency_count) == 1 ]]
[[ $(cloudflare_dependent_certificates) == cf-cert ]]

# Missing credentials must block an automatic Cloudflare renewal, not fall back
# to HTTP/manual validation or fail destructively.
rm -f "$CLOUDFLARE_INI"
result=''
renew_one_certificate cf-cert result
[[ $result == blocked ]]

help=$(show_help)
grep -Fq 'cert cloudflare' <<<"$help"
grep -Fq 'Global API Key' <<<"$help"
SH

# Certbot environment guard regression tests: low-memory pip behavior, exact
# plugin/core version coupling, no repeated healthy installs, and nginx renewal
# self-healing.
CASE2="$TMP/certenv"
mkdir -p "$CASE2/cfg" "$CASE2/certs" "$CASE2/bin" "$CASE2/certbot-venv/bin" "$CASE2/certbot-config/renewal"

SBCTL_TESTING=1 \
SBCTL_CONFIG_DIR="$CASE2/cfg" \
SBCTL_CONFIG_FILE="$CASE2/cfg/config.json" \
SBCTL_META_FILE="$CASE2/meta.json" \
SBCTL_CERT_DIR="$CASE2/certs" \
SBCTL_BACKUP_DIR="$CASE2/backups" \
SBCTL_DATA_DIR="$CASE2/data" \
SBCTL_COMMAND_PATH="$CASE2/bin/sbctl" \
SBCTL_SYMLINK_PATH="$CASE2/bin/sbctl-link" \
SBCTL_LOCK_FILE="$CASE2/lock" \
SBCTL_CERTBOT_VENV="$CASE2/certbot-venv" \
SBCTL_CERTBOT_CONFIG_DIR="$CASE2/certbot-config" \
SBCTL_CERTBOT_WORK_DIR="$CASE2/certbot-work" \
SBCTL_CERTBOT_LOGS_DIR="$CASE2/certbot-logs" \
SBCTL_CLOUDFLARE_INI="$CASE2/cloudflare.ini" \
CERTENV_TEST_CASE="$CASE2" \
bash <<'SH2'
set -Eeuo pipefail
source ./sbctl.sh

# Preserve SIGKILL/timeout status instead of collapsing it to a generic failure.
printf '#!/bin/sh\nexit 0\n' >"$CERTBOT_VENV/bin/pip"
chmod +x "$CERTBOT_VENV/bin/pip"
_cert_run_bounded() { return 137; }
if certbot_pip_install 'test component' 'dummy-package'; then rc=0; else rc=$?; fi
[[ $rc == 137 ]]

# Core bootstrap installs the supported 5.x range and matching nginx plugin once.
CALLS="$CERTENV_TEST_CASE/pip-calls"
CORE_READY="$CERTENV_TEST_CASE/core-ready"
NGINX_READY="$CERTENV_TEST_CASE/nginx-ready"
: >"$CALLS"
_certbot_prepare_venv() { return 0; }
certbot_version_supported() { [[ -e $CORE_READY ]]; }
certbot_core_version() { [[ -e $CORE_READY ]] && printf '5.7.0' || return 1; }
certbot_distribution_version() {
  case $1 in
    certbot) [[ -e $CORE_READY ]] && printf '5.7.0' || return 1 ;;
    certbot-nginx) [[ -e $NGINX_READY ]] && printf '5.7.0' || return 1 ;;
    certbot-dns-cloudflare) return 1 ;;
    *) return 1 ;;
  esac
}
certbot_distribution_matches_core() {
  local installed
  installed=$(certbot_distribution_version "$1") || return 1
  [[ $installed == 5.7.0 ]]
}
certbot_nginx_available() { [[ -e $NGINX_READY ]]; }
certbot_pip_check() { return 0; }
certbot_pip_install() {
  printf '%s\n' "$*" >>"$CALLS"
  case "$*" in
    *'certbot>=5.4,<6'*) touch "$CORE_READY" ;;
    *'certbot-nginx==5.7.0'*) touch "$NGINX_READY" ;;
  esac
  return 0
}
meta_resource_register() { :; }

ensure_certbot_environment
first_count=$(wc -l <"$CALLS")
[[ $first_count == 2 ]]
grep -Fq 'certbot>=5.4,<6' "$CALLS"
grep -Fq 'certbot-nginx==5.7.0' "$CALLS"
! grep -Fq -- '--no-deps' "$CALLS"
ensure_certbot_environment
second_count=$(wc -l <"$CALLS")
[[ $second_count == "$first_count" ]]

# An nginx renewal lineage must verify/repair its plugin before invoking Certbot.
NGINX_ENSURE="$CERTENV_TEST_CASE/nginx-ensure"
CERTBOT_ARGS="$CERTENV_TEST_CASE/certbot-renew-args"
ensure_certbot_nginx_plugin() { printf 'called\n' >>"$NGINX_ENSURE"; }
CERTBOT_BIN="$CERTENV_TEST_CASE/fake-certbot"
cat >"$CERTBOT_BIN" <<'BIN'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${CERTENV_TEST_CASE}/certbot-renew-args"
BIN
chmod +x "$CERTBOT_BIN"
printf 'authenticator = nginx\n' >"$CERTBOT_CONFIG_DIR/renewal/nginx.example.conf"
certbot_cmd renew --cert-name nginx.example --quiet
[[ $(wc -l <"$NGINX_ENSURE") == 1 ]]
grep -Fxq -- 'renew' "$CERTBOT_ARGS"
grep -Fxq -- '--cert-name' "$CERTBOT_ARGS"
grep -Fxq -- 'nginx.example' "$CERTBOT_ARGS"

# Cloudflare follows the current Certbot release and leaves SDK dependencies to
# certbot-dns-cloudflare package metadata.
CF_READY="$CERTENV_TEST_CASE/cf-ready"
CF_PIP_ARGS="$CERTENV_TEST_CASE/cf-pip-args"
ensure_certbot_environment() { return 0; }
certbot_core_version() { printf '5.7.0'; }
certbot_distribution_version() {
  case $1 in
    certbot) printf '5.7.0' ;;
    certbot-dns-cloudflare) [[ -e $CF_READY ]] && printf '5.7.0' || return 1 ;;
    *) return 1 ;;
  esac
}
certbot_distribution_matches_core() { [[ $1 == certbot-dns-cloudflare && -e $CF_READY ]]; }
cloudflare_plugin_available() { [[ -e $CF_READY ]]; }
certbot_pip_check() { return 0; }
certbot_pip_install() {
  printf '%s\n' "$*" >"$CF_PIP_ARGS"
  touch "$CF_READY"
}
ensure_cloudflare_certbot_plugin

grep -Fq 'certbot-dns-cloudflare==5.7.0' "$CF_PIP_ARGS"
! grep -Fq -- '--no-deps' "$CF_PIP_ARGS"
! grep -Fq 'cloudflare<' "$CF_PIP_ARGS"
SH2

echo 'Cloudflare DNS validation tests passed.'
