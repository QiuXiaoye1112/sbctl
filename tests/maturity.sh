#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

bash -n sbctl.sh
bash -n src/platform.sh src/state.sh src/service.sh
bash -n install.sh
sh -n alpine/install.sh
grep -Fq '# BEGIN MODULE LOADER' sbctl.sh
grep -Fq '/dist/sbctl' install.sh
grep -Fq '/dist/sbctl' alpine/install.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
MOCK="$TMP/mock"
CASE="$TMP/case"
mkdir -p "$MOCK" "$CASE/cfg" "$CASE/certs" "$CASE/bin" "$CASE/systemd" "$CASE/hooks"

cat >"$MOCK/systemctl" <<'SH'
#!/usr/bin/env sh
case "$1" in
  is-active|is-enabled|list-unit-files) exit 1 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$MOCK/systemctl"

CASE="$CASE" \
PATH="$MOCK:$PATH" \
SBCTL_TESTING=1 \
SBCTL_CONFIG_DIR="$CASE/cfg" \
SBCTL_CONFIG_FILE="$CASE/cfg/config.json" \
SBCTL_META_FILE="$CASE/meta.json" \
SBCTL_CERT_DIR="$CASE/certs" \
SBCTL_BACKUP_DIR="$CASE/backups" \
SBCTL_DATA_DIR="$CASE/data" \
SBCTL_SYSTEMD_UNIT_DIR="$CASE/systemd" \
SBCTL_COMMAND_PATH="$CASE/bin/sbctl" \
SBCTL_SYMLINK_PATH="$CASE/bin/sbctl-link" \
SBCTL_LOCK_FILE="$CASE/lock" \
SBCTL_CERTBOT_HOOK_DIR="$CASE/hooks" \
SBCTL_CERTBOT_VENV="$CASE/certbot-venv" \
SBCTL_CERTBOT_CONFIG_DIR="$CASE/certbot-config" \
SBCTL_CERTBOT_WORK_DIR="$CASE/certbot-work" \
SBCTL_CERTBOT_LOGS_DIR="$CASE/certbot-logs" \
bash <<'BASH'
set -Eeuo pipefail
source ./sbctl.sh
ensure_dependencies() { :; }
sing_box_installed() { return 1; }

write_default_config
[[ $SBCTL_VERSION == 0.4.3 ]]

# Generated service definitions should include explicit sbctl hardening.
create_service_definition
unit="$SYSTEMD_UNIT_DIR/$SERVICE_NAME.service"
grep -Fxq 'UMask=0077' "$unit"
grep -Fxq 'NoNewPrivileges=true' "$unit"
grep -Fxq 'ProtectSystem=strict' "$unit"
grep -Fxq 'PrivateTmp=true' "$unit"
grep -Fxq "ReadWritePaths=$DATA_DIR" "$unit"
[[ $(meta_resource_get serviceDefinition) == "$unit" ]]
[[ $(meta_resource_get dataDir) == "$DATA_DIR" ]]

# Public IPv4 discovery must fail over instead of trusting one external site.
curl() {
  local arg
  for arg in "$@"; do
    case $arg in
      *api.ipify.org*) printf 'not-an-ip'; return 0;;
      *checkip.amazonaws.com*) printf '198.51.100.7\n'; return 0;;
      *cloudflare.com/cdn-cgi/trace*) printf 'ip=203.0.113.9\n'; return 0;;
    esac
  done
  return 1
}
[[ $(detect_public_ipv4) == 198.51.100.7 ]]
unset -f curl

# Config and metadata are one transaction: restart failure restores both.
cat >"$CONFIG_FILE" <<'JSON'
{"log":{"level":"warn"},"inbounds":[{"type":"socks","tag":"old","listen":"127.0.0.1","listen_port":20001,"users":[]}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}
JSON
init_meta
meta_set_inbound old old.example.com ''
candidate=$(temp_file)
meta_candidate=$(temp_file)
jq '(.inbounds[0].tag)="new"' "$CONFIG_FILE" >"$candidate"
jq '.inbounds.new=.inbounds.old | del(.inbounds.old)' "$META_FILE" >"$meta_candidate"
service_is_active() { return 0; }
restart_service_checked() { return 1; }
if apply_candidate_with_meta "$candidate" "$meta_candidate"; then
  echo 'transaction unexpectedly succeeded' >&2
  exit 1
fi
[[ $(jq -r '.inbounds[0].tag' "$CONFIG_FILE") == old ]]
[[ $(jq -r '.inbounds.old.host' "$META_FILE") == old.example.com ]]
[[ $(jq -r '.inbounds.new // empty' "$META_FILE") == '' ]]
rm -f "$candidate" "$meta_candidate"
service_is_active() { return 1; }
restart_service_checked() { return 0; }

# Deleting one inbound cleans all route refs while preserving shared rules.
cat >"$CONFIG_FILE" <<'JSON'
{
  "inbounds":[
    {"type":"socks","tag":"a","listen":"127.0.0.1","listen_port":21001,"users":[]},
    {"type":"socks","tag":"b","listen":"127.0.0.1","listen_port":21002,"users":[]}
  ],
  "outbounds":[{"type":"direct","tag":"direct"},{"type":"direct","tag":"proxy"}],
  "route":{"final":"direct","rules":[
    {"inbound":["a"],"action":"route","outbound":"proxy"},
    {"inbound":["a","b"],"action":"route","outbound":"proxy"},
    {"inbound":["b"],"action":"route","outbound":"proxy"}
  ]}
}
JSON
init_meta
meta_set_inbound a a.example.com ''
meta_set_inbound b b.example.com ''
delete_inbound a 1
! jq -e '.inbounds[]|select(.tag=="a")' "$CONFIG_FILE" >/dev/null
! jq -e '.route.rules[]?|select(((.inbound // [])|type)=="array" and ((.inbound // [])|index("a"))!=null)' "$CONFIG_FILE" >/dev/null
[[ $(jq '[.route.rules[]?|select((.inbound // [])==["b"])]|length' "$CONFIG_FILE") == 2 ]]
[[ $(jq -r '.inbounds.a // empty' "$META_FILE") == '' ]]

# Multi-account Certbot: lineage wins; otherwise explicit account is forwarded.
mkdir -p "$CERTBOT_CONFIG_DIR/accounts/acme-v02.api.letsencrypt.org/directory/acct1"
mkdir -p "$CERTBOT_CONFIG_DIR/accounts/acme-v02.api.letsencrypt.org/directory/acct2"
printf '{}\n' >"$CERTBOT_CONFIG_DIR/accounts/acme-v02.api.letsencrypt.org/directory/acct1/regr.json"
printf '{}\n' >"$CERTBOT_CONFIG_DIR/accounts/acme-v02.api.letsencrypt.org/directory/acct2/regr.json"
mkdir -p "$CERTBOT_CONFIG_DIR/renewal"
printf 'account = acct1\n' >"$CERTBOT_CONFIG_DIR/renewal/existing.example.conf"
SBCTL_CERTBOT_ACCOUNT=acct2
chosen=''
select_certbot_account chosen existing.example
[[ $chosen == acct1 ]]
select_certbot_account chosen new.example
[[ $chosen == acct2 ]]
args_file="$CASE/certbot-args"
certbot_cmd() { printf '%s\n' "$@" >"$args_file"; }
certbot_issue_cmd new.example certonly -d new.example
awk 'p==1 && $0=="acct2"{ok=1} $0=="--account"{p=1;next} END{exit !ok}' "$args_file"

# Erase must not alter congestion control without an sbctl-owned marker.
if [[ ! -e /etc/sysctl.d/99-sbctl-bbr.conf ]]; then
  sysctl() { printf 'called\n' >>"$CASE/sysctl-called"; }
  _remove_bbr_settings
  [[ ! -e $CASE/sysctl-called ]]
fi

declare -f platform_apt_get | grep -Fq 'Acquire::Retries=2'
declare -f platform_apt_get | grep -Fq 'Acquire::ForceIPv4=true'
BASH

# Production systemd service summary — single systemctl show call via _service_states
CASE2="$TMP/systemd-prod"
MOCK2="$CASE2/bin"
mkdir -p "$MOCK2" "$CASE2/cfg" "$CASE2/certs" "$CASE2/data"

cat >"$MOCK2/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >>"${CASE2}/syscalls"
# systemctl show sing-box -p LoadState -p ActiveState -p UnitFileState --no-pager
case "$*" in
  *show*LoadState*|*show*ActiveState*|*show*UnitFileState*)
    printf 'LoadState=loaded\nActiveState=active\nUnitFileState=enabled\n'
    exit 0 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$MOCK2/systemctl"

cat >"$MOCK2/sing-box" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *version*) printf 'sing-box version 1.14.0\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$MOCK2/sing-box"

CASE="$CASE2" \
CASE2="$CASE2" \
PATH="$MOCK2:$PATH" \
SBCTL_TESTING=0 \
SBCTL_SING_BOX_BIN="$MOCK2/sing-box" \
SBCTL_CONFIG_DIR="$CASE2/cfg" \
SBCTL_CONFIG_FILE="$CASE2/cfg/config.json" \
SBCTL_META_FILE="$CASE2/meta.json" \
SBCTL_CERT_DIR="$CASE2/certs" \
SBCTL_BACKUP_DIR="$CASE2/backups" \
SBCTL_DATA_DIR="$CASE2/data" \
SBCTL_SYSTEMD_UNIT_DIR="$CASE2/systemd" \
SBCTL_COMMAND_PATH="$CASE2/bin/sbctl" \
SBCTL_SYMLINK_PATH="$CASE2/bin/sbctl-link" \
SBCTL_LOCK_FILE="$CASE2/lock" \
SBCTL_CERTBOT_HOOK_DIR="$CASE2/hooks" \
SBCTL_CERTBOT_VENV="$CASE2/certbot-venv" \
SBCTL_CERTBOT_CONFIG_DIR="$CASE2/certbot-config" \
SBCTL_CERTBOT_WORK_DIR="$CASE2/certbot-work" \
SBCTL_CERTBOT_LOGS_DIR="$CASE2/certbot-logs" \
bash <<'BASH2'
set -Eeuo pipefail
source ./sbctl.sh

init_system() { printf 'systemd'; }
sing_box_installed() { return 0; }

result=$(_service_summary_all)
calls=$(wc -l <"${CASE2}/syscalls" 2>/dev/null || printf 0)

if [[ $result != "运行中	已开启	1.14.0" ]]; then
  printf 'FAIL: expected "运行中	已开启	1.14.0", got "%s"\n' "$result" >&2
  exit 1
fi
if ((calls != 1)); then
  printf 'FAIL: expected 1 systemctl call, got %d\n' "$calls" >&2
  exit 1
fi
BASH2

echo 'maturity hardening tests passed.'
