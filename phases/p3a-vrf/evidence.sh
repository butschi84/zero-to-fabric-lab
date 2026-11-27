#!/usr/bin/env bash
# Phase 3a evidence: tenants as VRFs, symmetric IRB, anycast gateway, DHCP relay,
# RT mismatch. Run after `make deploy PHASE=p3a-vrf`. Writes evidence/p3a-vrf/.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB=ztf-p3a OUT="$HERE/../../evidence/p3a-vrf"
source "$HERE/../../scripts/lib.sh"
rm -f "$OUT"/P3a-0[1-9]*.txt "$OUT"/P3a-0[1-9]*.png "$OUT"/*.pcap "$OUT"/*.csv   # P3a-00 = graph screenshot, kept
LEAFS="leaf1 leaf2 leaf3"
wait_srl spine1 spine2 $LEAFS
NB="show network-instance default protocols bgp neighbor"
evpn_up() { [ "$(srl "$1" "$NB" | grep -c 'established')" -ge 4 ]; }
for l in $LEAFS; do wait_for 240 evpn_up $l; done
has_route() { local o; o=$(srl "$1" "show network-instance $2 route-table"); [[ "$o" == *"$3"* ]]; }
wait_for 120 has_route leaf1 corp 10.1.2.0/24
# Every static host speaks once, so the fabric has learned it (ARP + EVPN).
for h in corp1 corp2 srv3 dhcpsrv; do hx $h ping -c1 -W1 "$(hx $h ip -4 -o addr show eth1 | awk '{print $4}' | sed 's/\.[0-9]*\/24/.1/')" >/dev/null 2>&1 || true; done
for h in guest1 guest2; do hx $h ping -c1 -W1 10.2.1.1 >/dev/null 2>&1 || true; done
hx mgmt2 ping -c1 -W1 10.3.1.1 >/dev/null 2>&1 || true
sleep 3

RT="route-table ipv4-unicast summary"
rtab() { srlt "$1" "show network-instance $2 $RT" "Prefix,Route Type,Active,Next-hop (Type),Next-hop Interface"; }
vrfs() {
  echo "leaf1# show network-instance summary   (tenant VRFs)"
  srlt leaf1 "show network-instance summary" "Name,Type,Oper state,Description" | grep -vE '^mgmt  |default|^mac-vrf'
  echo; echo "leaf1# show network-instance corp $RT"; rtab leaf1 corp | grep -vE '\.255/32|\.1/32  '
  echo; echo "leaf3# show network-instance corp $RT   (/24 only)"; rtab leaf3 corp | grep -E '^Prefix|^---|/24|^  '
}
shot P3a-01 vrf-list-route-tables leaf1 - vrfs

T5="show network-instance default protocols bgp routes evpn route-type 5 summary"
T2="show network-instance default protocols bgp routes evpn route-type 2 summary"
routes() {
  echo "leaf1# $T5   (best paths, compact)"
  srlt leaf1 "$T5" "Status,Route-distinguisher,IP-address,Next-Hop,Label" | grep -E 'Status|----|u\*>' | grep -E 'Status|----|/24|10\.1\.2\.10'
  echo; echo "leaf1# $T2   (hosts with IP, best paths)"
  srlt leaf1 "$T2" "Status,Route-distinguisher,MAC-address,IP-address,Next-Hop,Label" | grep -E 'Status|----' ; srlt leaf1 "$T2" "Status,Route-distinguisher,MAC-address,IP-address,Next-Hop,Label" | grep 'u\*>' | grep -E '02:00:00:0[12]' | grep -v '0\.0\.0\.0'
  echo; echo "leaf1# ... route-type 5 prefix 10.1.2.0/24 detail   (label = L3VNI, RT, router MAC)"
  srl leaf1 "show network-instance default protocols bgp routes evpn route-type 5 prefix 10.1.2.0/24 detail" | grep -E 'Route Distinguisher|ip-prefix  |Label|BGP next-hop|Communities' | head -5
}
shot P3a-02 type5-type2-routes leaf1 - routes

agw() {
  for l in leaf1 leaf2; do
    echo "$l# info from state interface irb0 subinterface 101 (address, anycast-gw)"
    srl $l "info from state interface irb0 subinterface 101 ipv4 address *" | grep -E 'address 10|anycast-gw true' | sed 's/^ */  /;s/ {$//'
    srl $l "info from state interface irb0 subinterface 101 anycast-gw" | grep -E 'anycast-gw-mac |virtual-router-id' | sed 's/^ */  /'
  done
  echo
  for h in corp1 corp2; do
    hx $h ip neigh flush dev eth1 >/dev/null 2>&1 || true
    echo "$h# ping -c 2 10.1.1.1; ip neigh show 10.1.1.1"
    hx $h ping -c 2 -i 0.3 10.1.1.1 | grep -E 'bytes from|packet loss'
    hx $h ip neigh show 10.1.1.1
  done
}
shot P3a-03 anycast-gateway leaf1 - agw

# P3a-04: symmetric IRB. corp1 (10.1.1.11, leaf1) -> srv3 (10.1.2.13, leaf3,
# network 02 only exists there): routed into the L3VNI 50001 on leaf1.
pcap_uplinks leaf1 6 P3a-04-symmetric-irb.pcap "udp port 4789"
sleep 2; hx corp1 ping -c 3 -i 0.5 10.1.2.13 >/dev/null; pcap_wait; pcap_merge P3a-04-symmetric-irb.pcap
irb() {
  echo "method: corp1 10.1.1.11 (leaf1, VLAN 101) ping srv3 10.1.2.13 (leaf3, VLAN 102), capture on leaf1 uplinks"
  echo
  docker run --rm -v "$OUT:/out" "$TOOLS_IMAGE" sh -c 'tshark -r /out/P3a-04-symmetric-irb.pcap -Y "icmp.type==8" -V 2>/dev/null | awk "/^Frame/{n++} n==1"' \
   | grep -E '^(Ethernet|Internet|User|Virtual)|Src:|Dst:|Source Address|Destination Address|Destination Port|VXLAN Network Identifier|Time to Live' | grep -v 'Address Resolution' | sed -n '1,22p'
  echo; echo "srv3# ip neigh  (who srv3 sees as the sender: the anycast gateway MAC, routed)"; hx srv3 ip neigh show dev eth1 | head -3
}
shot P3a-04 symmetric-irb-capture leaf1 "tshark -V (first echo request, header lines)" irb

# P3a-05: isolation guest -> corp.
iso() {
  echo "guest1# ping -c 3 10.1.1.11   (corp1)"; hx guest1 ping -c 3 -i 0.3 -W 1 10.1.1.11 2>&1 | grep -E 'From|packet loss' | head -4
  echo "guest1# ping -c 3 10.2.1.12   (guest2, same tenant, other leaf)"; hx guest1 ping -c 3 -i 0.3 10.2.1.12 | grep 'packet loss'
  echo; echo "leaf1# show network-instance guest $RT"; rtab leaf1 guest | grep -vE '\.255/32|\.1/32  '
  echo; echo "leaf1# info from state network-instance guest route-table ipv4-unicast statistics"
  srl leaf1 "info from state network-instance guest route-table ipv4-unicast statistics" | grep -E 'active-routes |total-routes ' | sed 's/^ */  /'
}
shot P3a-05 isolation-guest-corp guest1 - iso

# P3a-06: DHCP relay with option 82 and a unique giaddr per leaf.
pcap dhcpsrv eth1 14 P3a-06-dhcp-relay.pcap "udp port 67"
sleep 2
lease1=$(hx dhcp1 sh -c 'ip addr flush dev eth1; timeout 10 udhcpc -i eth1 -n -q -t 4 2>&1 | tail -1')
lease2=$(hx dhcp2 sh -c 'ip addr flush dev eth1; timeout 10 udhcpc -i eth1 -n -q -t 4 2>&1 | tail -1')
pcap_wait
dhcp() {
  echo "method: udhcpc on dhcp1 (leaf1) and dhcp2 (leaf2), both VLAN 101; capture on the server port (dhcpsrv eth1)"
  echo
  docker run --rm -v "$OUT:/out" "$TOOLS_IMAGE" tshark -r /out/P3a-06-dhcp-relay.pcap -T fields -E separator='|' \
    -e ip.src -e ip.dst -e dhcp.option.dhcp -e dhcp.hw.mac_addr -e dhcp.ip.relay -e dhcp.ip.your -e dhcp.option.agent_information_option.agent_circuit_id -e dhcp.option.agent_information_option.agent_remote_id 2>/dev/null \
    | python3 "$REPO_ROOT/tools/dhcp_table.py" | sed -n '1,14p'
  echo; echo "dhcp1# udhcpc  -> $lease1"; echo "dhcp2# udhcpc  -> $lease2"
  echo "dhcp1# ip -4 addr show eth1"; hx dhcp1 ip -4 -o addr show eth1 | awk '{print "  "$4}'
}
shot P3a-06 dhcp-relay-option82 dhcpsrv - dhcp

reg() { for l in leaf1 leaf2 leaf3; do vrf_register $l | { [ $l = leaf1 ] && cat || tail -n +2; }; done; }
shot P3a-07 numbering-register leaf1 "register from running state (info from state ... | as json), all leafs" reg

# P3a-08: route-target mismatch. leaf3 exports corp with a wrong RT (50010
# instead of 50001). leaf1 drops routes nothing imports; keep-all-routes (a
# troubleshooting switch) keeps them in the EVPN table, not in the VRF.
P="10.1.2.0/24"
cfg leaf3 "set / network-instance corp protocols bgp-vpn bgp-instance 1 route-target export-rt target:65000:50010"; sleep 15
a_spine=$(srl spine1 "show network-instance default protocols bgp routes evpn route-type 5 prefix $P detail" | grep -m1 Communities | sed 's/^ *//')
a_leaf=$(srl leaf1 "$T5" | grep -c "$P" || true)
cfg leaf1 "set / network-instance default protocols bgp afi-safi evpn evpn keep-all-routes true"; sleep 8
b_leaf=$(srlt leaf1 "$T5" "Status,Route-distinguisher,IP-address,neighbor,Label" | grep -E 'Status|----|10\.1\.2\.0')
b_rt=$(srl leaf1 "show network-instance default protocols bgp routes evpn route-type 5 prefix $P detail" | grep -m1 Communities | sed 's/^ *//')
b_vrf=$(srl leaf1 "show network-instance corp route-table" | grep -c "$P" || true)
b_ping=$(hx corp1 ping -c 2 -W 1 10.1.2.13 2>&1 | grep 'packet loss' || true)
cfg leaf1 "delete / network-instance default protocols bgp afi-safi evpn evpn keep-all-routes"
cfg leaf3 "set / network-instance corp protocols bgp-vpn bgp-instance 1 route-target export-rt target:65000:50001"; sleep 15
c_vrf=$(srl leaf1 "show network-instance corp route-table" | grep -c "$P" || true)
c_ping=$(hx corp1 ping -c 2 -W 1 10.1.2.13 2>&1 | grep 'packet loss' || true)
rtm() {
  echo "fault: leaf3 exports VRF corp with export-rt target:65000:50010 (correct: 65000:50001)"
  echo
  echo "spine1 (route reflector) has the route, with the wrong RT:"; echo "  $a_spine"
  echo "leaf1 EVPN table, entries for $P (default: routes no VRF imports are dropped): $a_leaf"
  echo
  echo "leaf1 with 'afi-safi evpn evpn keep-all-routes true' (troubleshooting only):"; echo "$b_leaf" | sed 's/^/  /'
  echo "  $b_rt"
  echo "leaf1 VRF corp route-table entries for $P: $b_vrf      (received, not imported)"
  echo "corp1# ping 10.1.2.13 -> $b_ping"
  echo
  echo "repaired (export-rt 65000:50001): VRF corp entries for $P: $c_vrf"; echo "corp1# ping 10.1.2.13 -> $c_ping"
}
shot P3a-08 rt-mismatch leaf1 - rtm

matrix() { ping_matrix tmp.txt "corp1 corp2 srv3 guest1 mgmt2" "corp1=10.1.1.11 corp2=10.1.1.12 srv3=10.1.2.13 guest2=10.2.1.12 mgmt2=10.3.1.12" "-I eth1"; cat "$OUT/tmp.txt"; rm -f "$OUT/tmp.txt"; }
shot P3a-09 ping-matrix corp1 "ping matrix, 3 pings each (same tenant: OK, other tenant: FAIL)" matrix

mem_table > "$OUT/memory.txt"
graph_export "$HERE/topology.clab.yml"
render_pngs
ls "$OUT"
