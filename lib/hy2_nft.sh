# nftables compatibility override for Hysteria2 port hopping.
# The dedicated sbctl_hy2_hop table already identifies ownership, so rules do
# not carry nft comments. This avoids parser differences around quoted comments.

hy2_hop_restore_all() {
  [[ $(uname -s) == Linux ]] || return 0
  init_meta
  [[ -f $CONFIG_FILE ]] || { hy2_hop_clear_rules; return 0; }
  local count tag range target start end cmd
  count=$(hy2_hop_enabled_count)
  if ((count == 0)); then
    hy2_hop_clear_rules
    return 0
  fi

  hy2_hop_ensure_backend
  if command_exists nft; then
    nft delete table inet sbctl_hy2_hop >/dev/null 2>&1 || true
    nft add table inet sbctl_hy2_hop
    nft 'add chain inet sbctl_hy2_hop prerouting { type nat hook prerouting priority dstnat; policy accept; }'
    while IFS=$'\t' read -r tag range; do
      [[ -n $tag && -n $range ]] || continue
      target=$(jq -r --arg tag "$tag" '.inbounds[]?|select(.tag==$tag and .type=="hysteria2")|.listen_port // empty' "$CONFIG_FILE" 2>/dev/null || true)
      validate_port "$target" || continue
      nft add rule inet sbctl_hy2_hop prerouting udp dport "$range" redirect to ":${target}"
    done < <(jq -r '.inbounds|to_entries[]|select(.value.hysteria2PortHopping.enabled==true)|[.key,.value.hysteria2PortHopping.range]|@tsv' "$META_FILE")
  else
    for cmd in iptables ip6tables; do
      command_exists "$cmd" || continue
      "$cmd" -t nat -N SBCTL_HY2_HOP >/dev/null 2>&1 || true
      "$cmd" -t nat -F SBCTL_HY2_HOP
      "$cmd" -t nat -C PREROUTING -p udp -j SBCTL_HY2_HOP >/dev/null 2>&1 || "$cmd" -t nat -A PREROUTING -p udp -j SBCTL_HY2_HOP
    done
    while IFS=$'\t' read -r tag range; do
      [[ -n $tag && -n $range ]] || continue
      target=$(jq -r --arg tag "$tag" '.inbounds[]?|select(.tag==$tag and .type=="hysteria2")|.listen_port // empty' "$CONFIG_FILE" 2>/dev/null || true)
      validate_port "$target" || continue
      start=${range%-*}; end=${range#*-}
      for cmd in iptables ip6tables; do
        command_exists "$cmd" || continue
        "$cmd" -t nat -A SBCTL_HY2_HOP -p udp --dport "${start}:${end}" -j REDIRECT --to-ports "$target"
      done
    done < <(jq -r '.inbounds|to_entries[]|select(.value.hysteria2PortHopping.enabled==true)|[.key,.value.hysteria2PortHopping.range]|@tsv' "$META_FILE")
  fi
}
