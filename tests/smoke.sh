#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

bash -n sbctl.sh
bash -n install.sh
sh -n alpine/install.sh

grep -q '^build_inbound()' src/inbound.sh
grep -q '^restore_backup()' src/state.sh
grep -q '^build_reality_tls()' src/security.sh
grep -q '"AnyTLS" "VLESS" "Hysteria2" "Trojan"' src/inbound.sh
grep -q 'META_FILE="${SBCTL_META_FILE:-/var/lib/sbctl/meta.json}"' sbctl.sh
grep -q -- '-c ${CONFIG_FILE}' src/service.sh

MOCK=$(mktemp -d)
trap 'rm -rf "$MOCK"' EXIT
cat >"$MOCK/sing-box" <<'SH'
#!/usr/bin/env bash
set -e
if [[ ${1-} == version ]]; then
  echo 'sing-box version 1.13.12'
elif [[ ${1-} == generate && ${2-} == uuid ]]; then
  echo '11111111-1111-4111-8111-111111111111'
elif [[ ${1-} == generate && ${2-} == reality-keypair ]]; then
  printf 'PrivateKey: priv_test\nPublicKey: pub_test\n'
elif [[ ${1-} == check ]]; then
  jq -e . "$3" >/dev/null
else
  echo "unsupported fake sing-box command: $*" >&2
  exit 1
fi
SH
chmod +x "$MOCK/sing-box"

cat >"$MOCK/systemctl" <<'SH'
#!/usr/bin/env sh
exit 0
SH
chmod +x "$MOCK/systemctl"

INSTALL_CASE="$MOCK/install"
mkdir -p "$INSTALL_CASE"
PATH="$MOCK:$PATH" \
SBCTL_TESTING=1 \
SBCTL_SING_BOX_BIN="$MOCK/sing-box" \
SBCTL_CONFIG_DIR="$INSTALL_CASE/cfg" \
SBCTL_CONFIG_FILE="$INSTALL_CASE/cfg/config.json" \
SBCTL_META_FILE="$INSTALL_CASE/meta.json" \
SBCTL_CERT_DIR="$INSTALL_CASE/certs" \
SBCTL_DATA_DIR="$INSTALL_CASE/data" \
SBCTL_SYSTEMD_UNIT_DIR="$INSTALL_CASE/systemd" \
SBCTL_COMMAND_PATH="$INSTALL_CASE/bin/sbctl" \
SBCTL_SYMLINK_PATH="$INSTALL_CASE/bin/sbctl-link" \
SBCTL_LOCK_FILE="$INSTALL_CASE/lock" \
bash -c '
  set -Eeuo pipefail
  source ./sbctl.sh
  install_sing_box_release(){
    write_default_config
    create_service_definition
    install_quick_command
  }
  install_or_update_sing_box
  [[ -x $QUICK_COMMAND ]]
  [[ -L $QUICK_SYMLINK ]]
  [[ -s $CONFIG_FILE ]]
  [[ -s $SYSTEMD_UNIT_DIR/${SERVICE_NAME}.service ]]
  "$SING_BOX_BIN" check -c "$CONFIG_FILE"
'

BASE="$MOCK/base"
mkdir -p "$BASE"
PATH="$MOCK:$PATH" \
SBCTL_TESTING=1 \
SBCTL_SING_BOX_BIN="$MOCK/sing-box" \
SBCTL_CONFIG_DIR="$BASE/cfg" \
SBCTL_CONFIG_FILE="$BASE/cfg/config.json" \
SBCTL_META_FILE="$BASE/meta.json" \
SBCTL_CERT_DIR="$BASE/certs" \
SBCTL_DATA_DIR="$BASE/data" \
SBCTL_SYSTEMD_UNIT_DIR="$BASE/systemd" \
SBCTL_CERTBOT_HOOK_DIR="$BASE/hooks" \
SBCTL_LOCK_FILE="$BASE/lock" \
bash -c '
  set -Eeuo pipefail
  source ./sbctl.sh
  write_default_config
  jq -e ".inbounds==[] and .outbounds[0].type==\"direct\" and .route.final==\"direct\"" "$CONFIG_FILE" >/dev/null
  "$SING_BOX_BIN" check -c "$CONFIG_FILE"
  create_service_definition
  unit="$SYSTEMD_UNIT_DIR/${SERVICE_NAME}.service"
  grep -Fq "ExecStart=${SING_BOX_BIN} run -D ${DATA_DIR} -c ${CONFIG_FILE}" "$unit"
  ! grep -Fq " -C " "$unit"
  write_certbot_hook example.com
  test -x "$CERTBOT_HOOK_DIR/sbctl-example.com"
'

VALUE_TEST="$MOCK/value-test"
mkdir -p "$VALUE_TEST"
SBCTL_SING_BOX_BIN="$MOCK/sing-box" bash -c '
  set -Eeuo pipefail
  source ./sbctl.sh
  result=""
  prompt_optional_positive_int result "Mbps" <<EOF
abc
0
100
EOF
  [[ $result == 100 ]]
'

CLIENT="$MOCK/client"
mkdir -p "$CLIENT"
SBCTL_SING_BOX_BIN="$MOCK/sing-box" \
SBCTL_CONFIG_DIR="$CLIENT/cfg" \
SBCTL_CONFIG_FILE="$CLIENT/cfg/config.json" \
SBCTL_META_FILE="$CLIENT/meta.json" \
SBCTL_CERT_DIR="$CLIENT/certs" \
SBCTL_LOCK_FILE="$CLIENT/lock" \
bash -c '
  set -Eeuo pipefail
  source ./sbctl.sh
  print_share(){ :; }
  write_default_config
  tmp=$(temp_file)
  jq ".inbounds += [{type:\"vless\",tag:\"vless-test\",listen:\"::\",listen_port:24446,users:[{name:\"base\",uuid:\"22222222-2222-4222-8222-222222222222\",flow:\"\"}]}]" "$CONFIG_FILE" >"$tmp"
  mv "$tmp" "$CONFIG_FILE"
  meta_set_host vless-test 1.2.3.4
  add_client vless-test <<<"alice"
  client_exists vless-test alice
  old=$(jq -r ".inbounds[]|select(.tag==\"vless-test\")|.users[]|select(.name==\"alice\")|.uuid" "$CONFIG_FILE")
  [[ $old == 11111111-1111-4111-8111-111111111111 ]]
  tmp=$(temp_file)
  jq "(.inbounds[]|select(.tag==\"vless-test\")|.users[]|select(.name==\"alice\")|.uuid)=\"33333333-3333-4333-8333-333333333333\"" "$CONFIG_FILE" >"$tmp"
  mv "$tmp" "$CONFIG_FILE"
  rotate_client_credential vless-test alice
  [[ $(jq -r ".inbounds[]|select(.tag==\"vless-test\")|.users[]|select(.name==\"alice\")|.uuid" "$CONFIG_FILE") == 11111111-1111-4111-8111-111111111111 ]]
  confirm(){ return 0; }
  delete_client vless-test alice
  ! client_exists vless-test alice

  tmp=$(temp_file)
  jq ".inbounds += [{type:\"anytls\",tag:\"reality-test\",listen:\"::\",listen_port:24447,users:[{name:\"u\",password:\"p\"}],tls:{enabled:true,server_name:\"www.microsoft.com\",reality:{enabled:true,handshake:{server:\"www.microsoft.com\",server_port:443},private_key:\"priv_test\",short_id:[\"0123abcd\"]}}}]" "$CONFIG_FILE" >"$tmp"
  mv "$tmp" "$CONFIG_FILE"
  meta_set_inbound reality-test 1.2.3.4 pub_test
  [[ $(reality_public_key reality-test) == pub_test ]]
  tmp=$(temp_file)
  jq "(.inbounds[]|select(.tag==\"reality-test\")|.tls.reality.private_key)=\"priv_changed\"" "$CONFIG_FILE" >"$tmp"
  mv "$tmp" "$CONFIG_FILE"
  if reality_public_key reality-test >/dev/null 2>&1; then
    echo "stale REALITY public key was accepted" >&2
    exit 1
  fi
'

RESTORE="$MOCK/restore"
mkdir -p "$RESTORE"
SBCTL_SING_BOX_BIN="$MOCK/sing-box" \
SBCTL_CONFIG_DIR="$RESTORE/cfg" \
SBCTL_CONFIG_FILE="$RESTORE/cfg/config.json" \
SBCTL_META_FILE="$RESTORE/meta.json" \
SBCTL_TRAFFIC_FILE="$RESTORE/traffic.json" \
SBCTL_CERT_DIR="$RESTORE/certs" \
SBCTL_BACKUP_DIR="$RESTORE/backups" \
SBCTL_LOCK_FILE="$RESTORE/lock" \
bash -c '
  set -Eeuo pipefail
  source ./sbctl.sh
  write_default_config
  meta_set_host backup-tag backup.example
  printf old >"$CERT_DIR/kept.crt"
  printf old >"$CERT_DIR/kept.key"
  traffic_init_file
  tmp=$(temp_file)
  jq ".inbounds.test={protocol:\"vless\",port:12345,deleted:false,daily:{\"2026-08-24\":4096}}" "$TRAFFIC_FILE" >"$tmp"
  install -m 600 "$tmp" "$TRAFFIC_FILE"; rm -f "$tmp"
  archive="$SBCTL_BACKUP_DIR/test.tar.gz"
  backup_all "$archive"
  meta_set_host backup-tag changed.example
  printf stale >"$CERT_DIR/stale.crt"
  printf stale >"$CERT_DIR/stale.key"
  tmp=$(temp_file); jq ".inbounds.test.daily[\"2026-08-24\"]=1" "$TRAFFIC_FILE" >"$tmp"; install -m 600 "$tmp" "$TRAFFIC_FILE"; rm -f "$tmp"
  confirm(){ return 0; }
  restore_backup "$archive"
  [[ $(jq -r ".inbounds[\"backup-tag\"].host" "$META_FILE") == backup.example ]]
  [[ -f $CERT_DIR/kept.crt && ! -e $CERT_DIR/stale.crt ]]
  [[ $(jq -r ".inbounds.test.daily[\"2026-08-24\"]" "$TRAFFIC_FILE") == 4096 ]]
'

run_generated_case() {
  local name=$1 input=$2 assertion=$3 expected_share=$4 expected_host=${5:-1.2.3.4} case_dir
  case_dir="$MOCK/$name"
  mkdir -p "$case_dir"
  SBCTL_SING_BOX_BIN="$MOCK/sing-box" \
  SBCTL_CONFIG_DIR="$case_dir/cfg" \
  SBCTL_CONFIG_FILE="$case_dir/cfg/config.json" \
  SBCTL_META_FILE="$case_dir/meta.json" \
  SBCTL_CERT_DIR="$case_dir/certs" \
  SBCTL_LOCK_FILE="$case_dir/lock" \
  TEST_INPUT="$input" TEST_ASSERTION="$assertion" TEST_SHARE="$expected_share" TEST_HOST="$expected_host" \
  bash -c '
    set -Eeuo pipefail
    source ./sbctl.sh
    detect_public_ipv4(){ return 1; }
    detect_public_ipv6(){ return 1; }
    add_inbound <<<"$TEST_INPUT"
    tag=$(jq -r .inbounds[0].tag "$CONFIG_FILE")
    jq -e "$TEST_ASSERTION" "$CONFIG_FILE" >/dev/null
    [[ $(jq -r --arg tag "$tag" ".inbounds[\$tag].host" "$META_FILE") == "$TEST_HOST" ]]
    share=$(print_share "$tag" "")
    grep -Fq "$TEST_SHARE" <<<"$share"
  '
}

run_generated_case anytls $'1\n\n\n1\n\n\n1.2.3.4\n24443\n\n\n' \
  '.inbounds[0].type=="anytls" and .inbounds[0].tls.reality.enabled==true' \
  '"type": "anytls"'

run_generated_case vless $'2\n\n\n1\n\n\n1.2.3.4\n24444\n\n' \
  '.inbounds[0].type=="vless" and .inbounds[0].users[0].flow=="xtls-rprx-vision" and .inbounds[0].tls.reality.enabled==true' \
  'security=reality'

run_generated_case trojan $'4\n\n\n1\n\n\n1.2.3.4\n24448\n\n\n' \
  '.inbounds[0].type=="trojan" and .inbounds[0].tls.reality.enabled==true' \
  'security=reality'

run_generated_case socks $'5\n\n127.0.0.1\n127.0.0.1\n24449\nalice\n\n' \
  '.inbounds[0].type=="socks" and .inbounds[0].users[0].username=="alice"' \
  '@127.0.0.1:24449' \
  '127.0.0.1'

run_generated_case http $'6\n\n127.0.0.1\n127.0.0.1\n24450\n\n' \
  '.inbounds[0].type=="http" and (.inbounds[0].users|length)==0' \
  'http://127.0.0.1:24450  无认证' \
  '127.0.0.1'

HY="$MOCK/hy2"
mkdir -p "$HY/certs"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=example.com' \
  -keyout "$HY/certs/example.com.key" -out "$HY/certs/example.com.crt" >/dev/null 2>&1
SBCTL_TESTING=1 \
SBCTL_SING_BOX_BIN="$MOCK/sing-box" \
SBCTL_CONFIG_DIR="$HY/cfg" \
SBCTL_CONFIG_FILE="$HY/cfg/config.json" \
SBCTL_META_FILE="$HY/meta.json" \
SBCTL_CERT_DIR="$HY/certs" \
SBCTL_LOCK_FILE="$HY/lock" \
bash -c '
  set -Eeuo pipefail
  source ./sbctl.sh
  detect_public_ipv4(){ return 1; }
  detect_public_ipv6(){ return 1; }
  add_inbound <<EOF2
3


1
24445




2

EOF2
  tag=$(jq -r .inbounds[0].tag "$CONFIG_FILE")
  jq -e ".inbounds[0].type==\"hysteria2\" and .inbounds[0].tls.enabled==true and .inbounds[0].obfs.type==\"salamander\"" "$CONFIG_FILE" >/dev/null
  share=$(print_share "$tag" "")
  grep -Fq "hysteria2://" <<<"$share"
'

if command -v sing-box >/dev/null 2>&1; then
  REAL=$(mktemp -d)
  trap 'rm -rf "$MOCK" "$REAL"' EXIT
  mkdir -p "$REAL/certs"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=example.com' -keyout "$REAL/certs/example.com.key" -out "$REAL/certs/example.com.crt" >/dev/null 2>&1
  KEYS=$(sing-box generate reality-keypair)
  PRIVATE=$(awk '/PrivateKey/ {print $NF; exit}' <<<"$KEYS" | tr -d '"')
  [[ -n $PRIVATE ]]
  UUID=$(sing-box generate uuid)
  SID=0123abcd
  cat >"$REAL/anytls-reality.json" <<JSON
{"log":{"level":"warn","timestamp":true},"inbounds":[{"type":"anytls","tag":"anytls-in","listen":"::","listen_port":24443,"users":[{"name":"test","password":"test-password"}],"tls":{"enabled":true,"server_name":"www.microsoft.com","reality":{"enabled":true,"handshake":{"server":"www.microsoft.com","server_port":443},"private_key":"$PRIVATE","short_id":["$SID"]}}}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}
JSON
  cat >"$REAL/vless-reality.json" <<JSON
{"log":{"level":"warn","timestamp":true},"inbounds":[{"type":"vless","tag":"vless-in","listen":"::","listen_port":24444,"users":[{"name":"test","uuid":"$UUID","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"www.microsoft.com","reality":{"enabled":true,"handshake":{"server":"www.microsoft.com","server_port":443},"private_key":"$PRIVATE","short_id":["$SID"]}}}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}
JSON
  cat >"$REAL/hy2-tls.json" <<JSON
{"log":{"level":"warn","timestamp":true},"inbounds":[{"type":"hysteria2","tag":"hy2-in","listen":"::","listen_port":24445,"users":[{"name":"test","password":"test-password"}],"obfs":{"type":"salamander","password":"obfs-password"},"tls":{"enabled":true,"server_name":"example.com","certificate_path":"$REAL/certs/example.com.crt","key_path":"$REAL/certs/example.com.key"}}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}
JSON
  for cfg in "$REAL"/*.json; do
    echo "checking $(basename "$cfg")"
    sing-box check -c "$cfg"
  done
fi

echo 'sbctl smoke tests passed.'
