#!/usr/bin/env bash
# Phase 2 evidence: L2VNI over EVPN/VXLAN (corp VLAN 101, VNI 10101).
# Run after `make deploy PHASE=p2-l2vni`. Writes evidence/p2-l2vni/.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB=ztf-p2 OUT="$HERE/../../evidence/p2-l2vni"
source "$HERE/../../scripts/lib.sh"
rm -f "$OUT"/P2-*.txt "$OUT"/P2-*.png "$OUT"/*.pcap "$OUT"/*.csv
LEAFS="leaf1 leaf2 leaf3"
wait_srl spine1 spine2 $LEAFS
NB="show network-instance default protocols bgp neighbor"
evpn_up() { [ "$(srl "$1" "$NB" | grep -c 'established')" -ge 4 ]; }
for l in $LEAFS; do wait_for 240 evpn_up $l; done
cfg() { printf 'enter candidate\n%s\ncommit now\n' "$2" | docker exec -i "$(c "$1")" sr_cli >/dev/null; }
# Learn every host once (quiet hosts are not in EVPN until they speak).
for h in client1 client2 client3 mobile; do hx $h ping -c1 -W1 10.1.1.11 >/dev/null 2>&1 || true; hx $h ping -c1 -W1 10.1.1.12 >/dev/null 2>&1 || true; done
sleep 3

vtep() {
  srl leaf1 "show tunnel-interface vxlan1 vxlan-interface 101 detail" | grep -vE '^-+$|^=+$|Summary|configured' | sed -n '1,16p'
  echo; echo "leaf1# info network-instance mac-vrf-101 protocols"
  srl leaf1 "info network-instance mac-vrf-101 protocols" | sed -n '1,9p'
}
shot P2-01 vtep-vni leaf1 "show tunnel-interface vxlan1 vxlan-interface 101 detail" vtep

shot P2-02 evpn-sessions leaf1 "$NB   (compact)" srlt leaf1 "$NB" "Peer,Group,Peer-AS,State,Uptime,AFI/SAFI,[Rx/Active/Tx]"

T3="show network-instance default protocols bgp routes evpn route-type 3 summary"
shot P2-03 type3-imet leaf1 "$T3   (compact)" srlt leaf1 "$T3" "Status,Route-distinguisher,Originator-IP,neighbor,Next-Hop"

T2D="show network-instance default protocols bgp routes evpn route-type 2 mac-address 02:00:00:00:10:12 detail"
t2d() { hx client1 ping -c1 -W1 10.1.1.12 >/dev/null; srl leaf1 "$T2D" | grep -vE '^-+$' | sed -n '1,24p'; }
shot P2-04 type2-detail leaf1 "ping 10.1.1.12; $T2D" t2d

MT="show network-instance mac-vrf-101 bridge-table mac-table all"
macs() { for l in leaf1 leaf2; do echo "$l# $MT"; srlt $l "$MT" "Address,Destination,Type" | grep -v '1A:'; echo; done; }
shot P2-05 mac-tables leaf1 - macs

# P2-06: ICMP inside VXLAN, captured on both uplinks of leaf1 (ECMP may pick either).
pcap_uplinks leaf1 6 P2-06-vxlan-icmp.pcap "udp port 4789"
sleep 2; hx client1 ping -c 3 -i 0.5 10.1.1.12 >/dev/null; pcap_wait; pcap_merge P2-06-vxlan-icmp.pcap
dec() {
  docker run --rm -v "$OUT:/out" "$TOOLS_IMAGE" sh -c 'tshark -r /out/P2-06-vxlan-icmp.pcap -Y "icmp.type==8" -V 2>/dev/null | awk "/^Frame/{n++} n==1"' \
   | grep -E '^(Frame|Ethernet|Internet|User|Virtual)|Src:|Dst:|Source Address|Destination Address|Source Port|Destination Port|VXLAN Network Identifier|Type: |Total Length|Time to Live' | grep -v 'Address Resolution' | sed -n '1,30p'
}
shot P2-06 vxlan-packet-decode leaf1 "tshark -r P2-06-vxlan-icmp.pcap -V -Y icmp.type==8   (first packet, header lines)" dec

# P2-07: MTU with DF bit, underlay IP MTU 1500 (default) vs 9000 (this lab's config).
fabric_ipmtu() {
  for s in spine1 spine2; do cfg $s "set / interface ethernet-1/{1,2,3} subinterface 0 ip-mtu $1"; done
  for l in $LEAFS; do cfg $l "set / interface ethernet-1/{49,50} subinterface 0 ip-mtu $1"; done; sleep 2
}
sweep() { local s; for s in 1400 1421 1422 1423 1450 1472 1473; do
  if hx client1 ping -M do -s $s -c 2 -i 0.2 -W 1 10.1.1.12 >/dev/null 2>&1; then r=OK; else r=FAIL; fi; echo "$1,$s,$((s+28)),$r"; done; }
fabric_ipmtu 1500; a=$(sweep 1500); fabric_ipmtu 9000; b=$(sweep 9000)
{ echo "underlay_ip_mtu,icmp_payload,ip_packet,result"; echo "$a"; echo "$b"; } > "$OUT/mtu.csv"
mtu() {
  echo "method: ping -M do (DF) -s <payload> client1 -> client2 (other leaf), 2 pings each"
  echo "host MTU 1500; fabric port MTU 9232; underlay subinterface ip-mtu as listed"
  echo "VXLAN adds 50 bytes (outer IP 20 + UDP 8 + VXLAN 8 + inner Ethernet 14)"
  echo
  printf '%-16s %-13s %-11s %s\n' "underlay ip-mtu" "ICMP payload" "IP packet" result
  { echo "$a"; echo "$b"; } | awk -F, '{printf "%-16s %-13s %-11s %s\n",$1,$2,$3,$4}'
}
shot P2-07 mtu-df-test client1 - mtu

AN="show arpnd neighbors"
arpnd() {
  echo "leaf2# show network-instance mac-vrf-101 bridge-table proxy-arp all   (IP/MAC pairs per origin)"
  srlt leaf2 "show network-instance mac-vrf-101 bridge-table proxy-arp all" "Neighbor,MAC Address,Type,State,Last Update"
  echo; echo "dynamic = learned on a local port; evpn = learned from a remote leaf's Type-2 MAC/IP route"
}
shot P2-11 arp-table-evpn-learned leaf2 - arpnd

# P2-08: ARP suppression. Capture ARP inside VXLAN on leaf3's uplinks while
# client1 asks for client2 (fresh ARP cache), with and without proxy-ARP.
arp_count() {
  hx client1 ip neigh flush dev eth1
  pcap_uplinks leaf3 5 "P2-08-arp-$1.pcap" "udp port 4789"; sleep 1.5
  hx client1 arping -c 3 -I eth1 10.1.1.12 >/dev/null 2>&1 || true; pcap_wait; pcap_merge "P2-08-arp-$1.pcap"
  docker run --rm -v "$OUT:/out" "$TOOLS_IMAGE" tshark -r "/out/P2-08-arp-$1.pcap" -Y "arp.opcode==1 && arp.dst.proto_ipv4==10.1.1.12" 2>/dev/null | wc -l | tr -d ' '
}
pa_before=$(srlt leaf1 "show network-instance mac-vrf-101 bridge-table proxy-arp all" "Neighbor,MAC Address,Type,State")
with=$(arp_count with-suppression)
for l in $LEAFS; do cfg $l "set / network-instance mac-vrf-101 bridge-table proxy-arp admin-state disable"; done; sleep 2
without=$(arp_count without-suppression)
for l in $LEAFS; do cfg $l "set / network-instance mac-vrf-101 bridge-table proxy-arp admin-state enable"; done
for h in client1 client2 client3 mobile; do hx $h ping -c1 -W1 10.1.1.11 >/dev/null 2>&1 || true; hx $h ping -c1 -W1 10.1.1.12 >/dev/null 2>&1 || true; done
arps() {
  echo "method: client1 arping -c 3 10.1.1.12 (ARP cache flushed); count ARP requests for"
  echo "        10.1.1.12 arriving VXLAN-encapsulated on leaf3's uplinks (a bystander VTEP)"
  echo; printf '%-34s %s\n' "proxy-ARP (ARP suppression) on" "$with ARP requests seen on leaf3"
  printf '%-34s %s\n' "proxy-ARP off" "$without ARP requests seen on leaf3"
  echo; echo "leaf1 proxy-ARP table before the test:"; echo "$pa_before"
}
shot P2-08 arp-suppression leaf3 - arps

# P2-09: BUM with ingress replication: one broadcast from client1 -> copies on leaf1's uplinks.
pcap_uplinks leaf1 5 P2-09-bum.pcap "udp port 4789"; sleep 1.5
hx client1 ping -b -c 1 -W 1 10.1.1.255 >/dev/null 2>&1 || true; pcap_wait; pcap_merge P2-09-bum.pcap
bum() {
  echo "method: client1 ping -b -c 1 10.1.1.255 (one broadcast frame); VXLAN packets"
  echo "        leaving leaf1 that carry it (inner dst ff:ff:ff:ff:ff:ff), per outer destination"
  echo
  docker run --rm -v "$OUT:/out" "$TOOLS_IMAGE" tshark -r /out/P2-09-bum.pcap -Y "eth.dst==ff:ff:ff:ff:ff:ff && ip.src==10.255.0.11" -T fields -E separator=, -e ip.src -e ip.dst -e vxlan.vni 2>/dev/null | tr -d '\\' \
    | awk -F, '{print $1" -> "$3"  (inner "$2" -> "$4")  VNI "$5}' | sort | uniq -c | awk '{c=$1; $1=""; printf "%s copy:%s\n", c, $0}'
  echo; echo "remote VTEPs in the flood list (Type-3 routes): $(srl leaf1 "$T3" | grep -c 'u\*>')"
}
shot P2-09 bum-ingress-replication leaf1 - bum

# P2-10: MAC mobility. "mobile" (02:00:00:00:10:13) moves from leaf1 to leaf2.
T2S="show network-instance default protocols bgp routes evpn route-type 2 summary"
mob() { srlt leaf3 "$T2S" "Status,Route-distinguisher,MAC-address,IP-address,Next-Hop,MAC Mobility" | grep -E 'MAC-add|----|10:13'; }
hx mobile ping -c1 -W1 10.1.1.11 >/dev/null 2>&1 || true; sleep 2
before=$(mob)
hx mobile sh -c 'ip addr del 10.1.1.13/24 dev eth1; ip link set eth1 down; ip link set eth2 up; ip addr add 10.1.1.13/24 dev eth2; arping -U -c 2 -I eth2 10.1.1.13 >/dev/null 2>&1; ping -c 2 -W 1 10.1.1.11 >/dev/null 2>&1' || true
sleep 12; after=$(mob)
mobility() {
  echo "move: mobile's link to leaf1 goes down, the same MAC/IP comes up on leaf2 (GARP + ping)"
  echo; echo "before (seen on leaf3):"; echo "$before"
  echo; echo "after:"; echo "$after"
}
shot P2-10 mac-mobility leaf3 - mobility
# move it back so the lab ends as deployed
hx mobile sh -c 'ip addr del 10.1.1.13/24 dev eth2; ip link set eth2 down; ip link set eth1 up; ip addr add 10.1.1.13/24 dev eth1; arping -U -c 2 -I eth1 10.1.1.13 >/dev/null 2>&1' || true

AFI="show network-instance default protocols bgp neighbor 10.255.0.1 detail"
afi() { srl leaf1 "$AFI" | grep -vE '^-+$' | grep -iE 'Peer :|Group :|session-state|Cap |AFI/SAFI|End of RIB|Received routes|Active routes|Sent routes' | sed -n '1,24p'; }
shot P2-12 overlay-session-afi leaf1 "$AFI   (filtered)" afi

matrix() { ping_matrix tmp.txt "client1 client2 client3" "client1=10.1.1.11 client2=10.1.1.12 client3=10.1.1.14 mobile=10.1.1.13" "-I eth1"; cat "$OUT/tmp.txt"; rm -f "$OUT/tmp.txt"; }
shot P2-13 ping-matrix client1 "ping matrix, 3 pings each (same L2 segment, three leafs)" matrix

mem_table > "$OUT/memory.txt"
graph_export "$HERE/topology.clab.yml"
render_pngs
ls "$OUT"
