#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

bash -n lib/cloudflare.sh

grep -Fq "'cloudflare<3'" lib/cloudflare.sh
grep -Fq -- '--no-deps "$plugin_spec"' lib/cloudflare.sh
grep -Fq 'SBCTL_PIP_TIMEOUT:-300' lib/cloudflare.sh
grep -Fq 'status == 137' lib/cloudflare.sh || grep -Fq '137)' lib/cloudflare.sh

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
[[ $(stat -c '%a' "$CLOUDFLARE_INI") == 600 ]]
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

echo 'Cloudflare DNS validation tests passed.'
