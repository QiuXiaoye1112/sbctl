# Terminal display-width helpers.
# Keep internal accumulator names distinct from caller output variables because
# Bash local variables use dynamic scope and `printf -v "$name"` otherwise
# writes into a callee-local variable with the same name.

display_width() {
  local __var=$1 value=$2 char code computed_width=0 i
  for ((i=0; i<${#value}; i++)); do
    char=${value:i:1}
    printf -v code '%d' "'$char"
    if ((code < 0 || code > 127)); then
      ((computed_width+=2))
    else
      ((computed_width+=1))
    fi
  done
  printf -v "$__var" '%s' "$computed_width"
}

print_table_cell() {
  local value=$1 target_width=$2 cell_width=0 padding
  display_width cell_width "$value"
  padding=$((target_width-cell_width))
  ((padding > 0)) || padding=1
  printf '%s%*s' "$value" "$padding" ''
}

print_table_cell_clipped() {
  local value=$1 target_width=$2 cell_width=0 limit clipped="" used=0 char char_width=0 i
  display_width cell_width "$value"
  if ((cell_width < target_width)); then
    print_table_cell "$value" "$target_width"
    return
  fi
  limit=$((target_width-4))
  ((limit > 0)) || limit=1
  for ((i=0; i<${#value}; i++)); do
    char=${value:i:1}
    display_width char_width "$char"
    ((used+char_width <= limit)) || break
    clipped+=$char
    ((used+=char_width))
  done
  print_table_cell "${clipped}..." "$target_width"
}
