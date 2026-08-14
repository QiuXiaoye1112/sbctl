#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
export SBCTL_TESTING=1
export SBCTL_SRC_DIR="$ROOT/src"
# shellcheck disable=SC1090
source "$ROOT/sbctl.sh"

width=""
display_width width "标签"
[[ $width == 4 ]]

width=""
display_width width "vless-test"
[[ $width == 10 ]]

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

out=$(print_table_cell_clipped "abcdefghijkl" 8)
[[ $out == "abcd... " ]]

printf 'sbctl UI tests passed.\n'
