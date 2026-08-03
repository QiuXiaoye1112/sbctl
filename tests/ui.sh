#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
export SBCTL_TESTING=1
export SBCTL_LIB_DIR="$ROOT/lib"
# shellcheck disable=SC1090
source "$ROOT/sbctl.sh"

width=""
display_width width "标签"
[[ $width == 4 ]]

width=""
display_width width "vless-test"
[[ $width == 10 ]]

out=$(print_table_cell "标签" 8)
[[ $out == "标签    " ]]

out=$(print_table_cell_clipped "abcdefghijkl" 8)
[[ $out == "abcd... " ]]

printf 'sbctl UI tests passed.\n'
