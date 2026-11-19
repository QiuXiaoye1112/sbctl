#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
export SBCTL_TESTING=1
export SBCTL_SRC_DIR="$ROOT/src"
export SBCTL_CONFIG_FILE="$fixture/config.json" SBCTL_META_FILE="$fixture/meta.json"
# shellcheck disable=SC1090
source "$ROOT/sbctl.sh"
trap 'cleanup_session_on_exit; rm -rf "$fixture"' EXIT

width=""
display_width width "标签"
[[ $width == 4 ]]

width=""
display_width width "anytls-test"
[[ $width == 11 ]]

(
  export LC_ALL=C
  width=""
  display_width width "匹配"
  [[ $width == 4 ]]
  width=""
  display_width width "子域名"
  [[ $width == 6 ]]
)

out=$(print_table_cell "标签" 8)
[[ $out == "标签    " ]]

out=$(print_table_cell "子域名" 6)
[[ $out == "子域名" ]]

out=$(print_table_cell_clipped "子域名" 6)
[[ $out == "子域名" ]]

out=$(print_table_cell_clipped "abcdefghijkl" 8)
[[ $out == "abcd... " ]]

out=$(print_table_cell_clipped "abcdefghijklmnopqrstuvwx" 24)
[[ $out == "abcdefghijklmnopqrstuvwx" ]]

cat >"$CONFIG_FILE" <<'JSON'
{"inbounds":[{"tag":"edge-quic","type":"hysteria2","listen_port":443,"tls":{"enabled":true},"users":[{"name":"alice"}]}],"outbounds":[]}
JSON
printf '%s\n' '{"certificates":{"edge.example":{}}}' >"$META_FILE"
_service_summary_all() { printf '已停止\t已开启\t1.13.18'; }
bbr_state_summary() { printf '未启用'; }

out=$(COLUMNS=80 main_menu <<<"0" 2>&1)
[[ $out == *'sbctl · sing-box 管理控制台'* && $out == *'服务 ○ 已停止'* && $out == *'托管证书 1 张'* ]]
[[ $out == *'代理与路由'*'1) 入站管理'*'2) 出站管理'*'3) TLS 证书'*'4) 流量信息'*'5) BBR 启用 / 关闭'*'6) 服务管理'*'7) 卸载'*'0) 退出'* ]]
[[ $out != *'[警告]'* && $out != *'[错误]'* && $out != *$'\033'* ]]
[[ $out == *'标签'*'协议'*'端口'*'edge-quic'*'Hysteria2'*'443'* ]]

out=$(COLUMNS=42 main_menu <<<"0" 2>&1)
[[ $out == *'edge-quic'*$'\n    Hysteria2 · tls · quic\n    端口 443 · 用户 1'* ]]
[[ $out == *'服务 / 自启'*'已停止 / 已开启'* ]]

out=$(COLUMNS=80 service_menu <<<"0")
[[ $out == *'1) 启动服务'* && $out == *'0) 返回主菜单'* ]]
_service_summary_all() { printf '运行中\t已开启\t1.13.18'; }
out=$(COLUMNS=80 service_menu <<<"0")
[[ $out == *'1) 停止服务'* ]]

printf 'sbctl UI tests passed.\n'
