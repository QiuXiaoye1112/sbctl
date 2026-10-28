#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export SBCTL_TESTING=1
source "$ROOT/sbctl.sh"
command_exists() { case "$1" in iptables|ip6tables|iptables-save|ip6tables-save|iptables-restore|ip6tables-restore) return 0;; *) return 1;; esac; }
save_fixture() {
  cat <<END
*filter
:INPUT ACCEPT [0:0]
:${TRAFFIC_IPTABLES_IN_CHAIN} - [0:0]
:${TRAFFIC_IPTABLES_OUT_CHAIN} - [0:0]
[3:30] -A INPUT -j DROP
[1:10] -A INPUT -j ${TRAFFIC_IPTABLES_IN_CHAIN}
[2:20] -A ${TRAFFIC_IPTABLES_IN_CHAIN} -m comment --comment sbctl-traffic:count:test -j RETURN
COMMIT
END
}
iptables-save() { save_fixture; }; ip6tables-save() { save_fixture; }
iptables-restore() { [[ $1 == --noflush ]]; cat >"$TMP/restored4"; }; ip6tables-restore() { [[ $1 == --noflush ]]; cat >"$TMP/restored6"; }
traffic_clear_iptables_rules() { :; }
traffic_build_iptables_rules() { return 1; }
if traffic_restore_iptables_rules; then exit 1; fi
for snapshot in "$TMP/restored4" "$TMP/restored6"; do
  grep -q 'sbctl-traffic:count:test' "$snapshot"
  grep -q -- '-I INPUT 2' "$snapshot"
  ! grep -q -- '-j DROP' "$snapshot"
  ! grep -q ':INPUT ACCEPT' "$snapshot"
done
iptables-save() { return 1; }
rm -f "$TMP/restored4" "$TMP/restored6"
if traffic_restore_iptables_rules; then exit 1; fi
[[ ! -e $TMP/restored4 && ! -e $TMP/restored6 ]]
echo 'iptables scoped dual-stack rollback tests passed' 
