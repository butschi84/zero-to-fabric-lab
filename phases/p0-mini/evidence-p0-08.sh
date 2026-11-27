#!/usr/bin/env bash
# P0-08: what changes per hop. client1 -> client2 (routed over leaf1, spine1, leaf2): ARP request and reply,
# then one ping, captured at four points at the same time. Shows that the MAC addresses change on every
# hop while the IP addresses stay the same (only the TTL counts down). Videos A1 / A4.
# Deploys the lab if it is not running; does NOT destroy it (make destroy PHASE=p0-mini).
# usage: bash phases/p0-mini/evidence-p0-08.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB=ztf-p0 OUT="$HERE/../../evidence/p0-mini"
source "$HERE/../../scripts/lib.sh"
CLAB="$REPO_ROOT/scripts/clab.sh"
cd "$HERE"
rm -f "$OUT"/P0-08*
docker ps --format '{{.Names}}' | grep -q "^clab-${LAB}-leaf1$" || "$CLAB" deploy -t topology.clab.yml >/dev/null 2>&1
wait_srl spine1 spine2 leaf1 leaf2
# routes of phase 0 are static and need the next hops resolved; give the fabric a moment after boot
wait_for 120 hx client1 ping -c 1 -W 1 10.10.2.10

# four capture points on the path; they run first, then every neighbour cache on the path is emptied, so the
# ARP exchanges that follow (SR Linux re-resolves its static next hops at once) are inside the captures
F="arp or icmp"
pcap client1 eth1 45 P0-08a-client1-eth1.pcap $F
pcap leaf1   e1-49 45 P0-08b-leaf1-e1-49.pcap $F
pcap spine1  e1-2 45 P0-08c-spine1-e1-2.pcap $F
pcap client2 eth1 45 P0-08d-client2-eth1.pcap $F
sleep 2
for n_if in "leaf1 ethernet-1/1" "leaf1 ethernet-1/49" "spine1 ethernet-1/1" "spine1 ethernet-1/2" "leaf2 ethernet-1/49" "leaf2 ethernet-1/1"; do
  set -- $n_if
  srl "$1" "tools interface $2 subinterface 0 ipv4 arp delete-dynamic" >/dev/null 2>&1 || true
done
# the clients last (sr_cli calls take seconds each), right before the ping
hx client1 ip neigh flush all >/dev/null 2>&1 || true
hx client2 ip neigh flush all >/dev/null 2>&1 || true
[ -z "$(hx client1 ip neigh show dev eth1)" ] || echo "WARN: client1 neighbour cache not empty" >&2
hx client1 ping -c 1 -W 2 10.10.2.10 > "$OUT/P0-08-ping.tmp" 2>&1 || true
pcap_wait

# interface MACs on the path (the legend for the tables)
mac_srl() { srl "$1" "info from state interface $2 ethernet hw-mac-address" | awk '/hw-mac-address/ {print $2}'; }
mac_lx()  { hx "$1" cat /sys/class/net/eth1/address; }
LEGEND="$OUT/P0-08-legend.tmp"   # bash 3 on macOS: no associative arrays
{ echo "client1 $(mac_lx client1)"
  echo "leaf1-e1-1 $(mac_srl leaf1 ethernet-1/1)";   echo "leaf1-e1-49 $(mac_srl leaf1 ethernet-1/49)"
  echo "spine1-e1-1 $(mac_srl spine1 ethernet-1/1)"; echo "spine1-e1-2 $(mac_srl spine1 ethernet-1/2)"
  echo "leaf2-e1-49 $(mac_srl leaf2 ethernet-1/49)"; echo "leaf2-e1-1 $(mac_srl leaf2 ethernet-1/1)"
  echo "client2 $(mac_lx client2)"; } | tr 'A-F' 'a-f' > "$LEGEND"

# one text per capture point: every frame with source/destination MAC and IP (ARP: the addresses it asks about)
fields() {
  docker run --rm -v "$OUT:/out" "$TOOLS_IMAGE" tshark -r "/out/$1" -n -T fields -E separator='|' \
    -e frame.time_relative -e eth.src -e eth.dst -e _ws.col.Protocol -e ip.src -e ip.dst -e ip.ttl -e arp.opcode \
    -e arp.src.proto_ipv4 -e arp.dst.proto_ipv4 -e icmp.type 2>/dev/null
}
point() {  # <id> <pcap> <node> <ifc> <where>
  local id="$1" p="$2" node="$3" ifc="$4" where="$5"
  fields "$p" | python3 "$REPO_ROOT/tools/hop_frames.py" "$LEGEND" > "$OUT/$id.tmp"
  { printf '# %s · %s %s · %s\n' "$(echo "$id" | cut -d- -f1-2)" "$node" "$ifc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'host# tshark -r %s -n   (%s)\n' "$p" "$where"
    head -26 "$OUT/$id.tmp"; } > "$OUT/$id.txt"
  rm -f "$OUT/$id.tmp"
}
point P0-08a-client1-eth1 P0-08a-client1-eth1.pcap client1 eth1  "client side"
point P0-08b-leaf1-e1-49  P0-08b-leaf1-e1-49.pcap  leaf1   e1-49 "between leaf1 and spine1"
point P0-08c-spine1-e1-2  P0-08c-spine1-e1-2.pcap  spine1  e1-2  "between spine1 and leaf2"
point P0-08d-client2-eth1 P0-08d-client2-eth1.pcap client2 eth1  "target side"

# the summary shot: the one echo request at each point
summary() {
  echo "ping -c 1 10.10.2.10 from client1; the same echo request seen at four points"
  echo
  for p in P0-08a-client1-eth1 P0-08b-leaf1-e1-49 P0-08c-spine1-e1-2 P0-08d-client2-eth1; do
    fields "$p.pcap" | python3 "$REPO_ROOT/tools/hop_frames.py" "$LEGEND" --request-only --point "$p"
  done
  echo
  echo "MAC addresses: new pair on every link.  IP addresses: 10.10.1.10 -> 10.10.2.10 end to end."
  echo "TTL: 64 at the client, minus one per router (leaf1, spine1, leaf2)."
  echo
  echo "interface MACs on the path:"
  awk '{printf "  %-12s %s\n", $1, $2}' "$LEGEND"
  echo
  grep -E 'transmitted|bytes from' "$OUT/P0-08-ping.tmp" | sed 's/^/  /'
}
shot P0-08 mac-per-hop host "tshark on client1 eth1, leaf1 e1-49, spine1 e1-2, client2 eth1" summary
rm -f "$OUT/P0-08-ping.tmp" "$OUT/P0-08-legend.tmp"
python3 "$REPO_ROOT/tools/render_term.py" "$OUT"/P0-08*.txt >/dev/null
ls "$OUT"/P0-08*
