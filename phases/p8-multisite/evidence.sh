#!/usr/bin/env bash
# Phase 8 evidence: two sites (two gateways each), DCI variant B, WAN
# realities, stretched L2 vs L3, branch with VRFs over IPsec, two WAN paths,
# gateway failure, site failure with service failover.
# Run after `make deploy PHASE=p8-multisite` (~8 min). The LAST tests stop
# site A (gateway first, then the whole site); run `make destroy` afterwards.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB=ztf-p8 OUT="$HERE/../../evidence/p8-multisite"
source "$HERE/../../scripts/lib.sh"
find "$OUT" -maxdepth 1 \( -name 'P8-*.txt' -o -name 'P8-*.png' -o -name '*.csv' -o -name '*.pcap' \) ! -name '*clab-graph*' -delete   # graph screenshot kept
CLAB="$REPO_ROOT/scripts/clab.sh"
NODES="spine-a leaf-a1 gw-a gw-a2 spine-b leaf-b1 gw-b gw-b2 br1"
wait_srl $NODES
NB="show network-instance default protocols bgp neighbor"
n_est() { srl "$1" "$NB" | grep -E "$2" | grep -c established || true; }
all_up() { [ "$(n_est gw-a dci)" -ge 2 ] && [ "$(n_est gw-b2 dci)" -ge 2 ] && [ "$(n_est br1 hubs)" -ge 4 ]; }
wait_for 300 all_up
has_route() { local o; o=$(srl "$1" "show network-instance $2 route-table"); [[ "$o" == *"$3"* ]]; }
wait_for 120 has_route leaf-a1 corp 10.1.3.0/24
wait_for 120 has_route br1 corp 10.9.100.10/32
for h in a-c1 a-c2 a-g1 b-c1 b-c3 br-c1 br-g1 srv-a srv-b; do gw=$(hx $h ip route show default | awk '{print $3}'); hx $h ping -c1 -W1 "$gw" >/dev/null 2>&1 || true; done
hx a-c1 ping -c1 -W1 10.1.1.21 >/dev/null 2>&1 || true; sleep 3
RT="route-table ipv4-unicast summary"
rtab() { srlt "$1" "show network-instance $2 $RT" "Prefix,Route Type,Route Owner,Next-hop (Type)"; }
T5="show network-instance default protocols bgp routes evpn route-type 5 summary"
okc() { hx "$1" ping -c 3 -i 0.2 -W 1 "$2" 2>&1 | grep -oE '[0-9]+ packets transmitted, [0-9]+ (packets )?received' | sed 's/ packets//g'; }
# capture on several ports of one node and merge into one file
pcap_ports() { local n="$1" secs="$2" file="$3" ports="$4"; shift 4; local p
  for p in $ports; do pcap "$n" "$p" "$secs" "${file%.pcap}.$p.part" "$@"; done; }
merge_ports() { local file="$1" ports="$2" p parts=""
  for p in $ports; do parts="$parts /out/${file%.pcap}.$p.part"; done
  docker run --rm -v "$OUT:/out" "$TOOLS_IMAGE" mergecap -w "/out/$file" $parts; rm -f "$OUT/${file%.pcap}".*.part; }

yaml() { echo "topology.clab.yml (excerpt: site B, WAN nodes, branch)"
  grep -E '^    (spine-b|leaf-b1|gw-b|gw-b2|br1|wan|wan1|wan2|ipsec-a|ipsec-b|ipsec-br|br-c1|br-g1):|"(gw-a|gw-b|gw-a2|gw-b2):e1-1"|ipsec-(br|a|b):eth2|br1:e1-49' "$HERE/topology.clab.yml" \
   | sed -E 's/(binds|labels): .*//; s/ +$//' | cut -c1-118 | head -28; }
shot P8-01 topology-yaml-excerpt gw-a - yaml

und() {
  echo "gw-a# $NB   (underlay over the WAN and to ipsec-a, overlay to the RR, DCI, branch)"
  srlt gw-a "$NB" "Peer,Group,Peer-AS,State,AFI/SAFI,[Rx/Active/Tx]"
  echo; echo "gw-a# ping site B loopbacks (leaf-b1 10.255.1.11, gw-b 10.255.1.21, gw-b2 10.255.1.22)"
  for ip in 10.255.1.11 10.255.1.21 10.255.1.22; do echo "  $ip: $(docker exec "$(c gw-a)" sr_cli -d "ping $ip network-instance default -c 2" 2>&1 | grep -oE '[0-9]+ (packets )?received' | head -1 || echo FAIL)"; done
}
shot P8-02 underlay-over-wan gw-a - und

evs() {
  echo "gw-b# $NB   (DCI sessions: both gateways of site A)"; srlt gw-b "$NB" "Peer,Group,Peer-AS,State,AFI/SAFI,[Rx/Active/Tx]" | grep -E 'Peer|---|dci'
  echo; echo "leaf-a1# $T5   (site A's view: prefixes of site B)"
  srlt leaf-a1 "$T5" "Status,Route-distinguisher,IP-address,Next-Hop,Label" | grep -E 'Status|---|u\*>' | grep -E 'Status|---|10\.1\.(1|3)\.0'
  echo; echo "leaf-b1# $T5   (site B's view: prefixes of site A)"
  srlt leaf-b1 "$T5" "Status,Route-distinguisher,IP-address,Next-Hop,Label" | grep -E 'Status|---|u\*>' | grep -E 'Status|---|10\.1\.(1|2)\.0'
}
shot P8-03 dci-evpn-sessions gw-b - evs

nh() {
  echo "variant built: B (gateways exchange EVPN routes by eBGP, next hop unchanged). No re-origination:"
  echo "the next hop seen in the other site is the originating LEAF, not the gateway."
  for side in "leaf-a1 10.1.3.0/24" "leaf-b1 10.1.2.0/24"; do read -r n p <<< "$side"; echo; echo "$n# ... route-type 5 prefix $p detail"
    srl $n "show network-instance default protocols bgp routes evpn route-type 5 prefix $p detail" | grep -E 'Route Distinguisher|Label|BGP next-hop|AS Path|Communities' | head -5 | sed 's/^ */  /'; done
}
shot P8-04 next-hop-not-reoriginated leaf-a1 - nh

l3() {
  echo "a-c2 (10.1.2.11, site A, network 02)# ping -c 3 10.1.3.21 (b-c3, site B, network 03)"
  hx a-c2 ping -c 3 -i 0.3 10.1.3.21 | grep -E 'packet loss|rtt' | sed 's/^/  /'
  echo "a-c2# traceroute -I -n 10.1.3.21"; hx a-c2 traceroute -I -n -q 1 -w 1 -m 6 10.1.3.21 | tail -n +2 | sed 's/^/  /'
  echo; echo "leaf-a1# show network-instance corp $RT   (prefixes from site B)"
  rtab leaf-a1 corp | grep -E '^Prefix|^---|^10\.1\.3\.'
}
shot P8-05 l3-between-sites a-c2 - l3

# P8-06: packet a-c2 -> b-c3 on the WAN (wan node eth1 / eth3 = gw-a / gw-a2 side, ECMP may use either).
pcap_ports wan 6 P8-06-wan-vxlan.pcap "eth1 eth3" "udp port 4789"; sleep 1.5; hx a-c2 ping -c 2 -i 0.5 10.1.3.21 >/dev/null; pcap_wait; merge_ports P8-06-wan-vxlan.pcap "eth1 eth3"
dec() {
  echo "method: a-c2 ping b-c3 (L3, VRF corp); capture on the WAN node's ports towards gw-a and gw-a2"
  docker run --rm -v "$OUT:/out" "$TOOLS_IMAGE" sh -c 'tshark -r /out/P8-06-wan-vxlan.pcap -Y "icmp.type==8" -V 2>/dev/null | awk "/^Frame/{n++} n==1"' \
   | grep -E '^(Ethernet|Internet|User|Virtual)|Source Address|Destination Address|Destination Port|VXLAN Network Identifier|Total Length' | grep -v 'Address Resolution' | sed -n '1,18p'
  echo; echo "outer IPs are the LEAF loopbacks (10.255.0.11 -> 10.255.1.11), not the gateways; the VNI is unchanged"
}
shot P8-06 wan-packet-decode wan "tshark -V (first echo request)" dec

# P8-07: MTU over the WAN (gateway WAN sub-interfaces ip-mtu 1500, then 9000).
GWS="gw-a gw-a2 gw-b gw-b2"
wan_mtu() { for gname in $GWS; do cfg $gname "set / interface ethernet-1/1 subinterface 0 ip-mtu $1"; done; sleep 2; }
sweep() { local s lbl="$1" src="$2" dst="$3"; shift 3; for s in "$@"; do
  if hx "$src" ping -M do -s $s -c 2 -i 0.2 -W 1 "$dst" >/dev/null 2>&1; then r=OK; else r=FAIL; fi; echo "$lbl,$s,$((s+28)),$r"; done; }
pcap a-c2 eth1 5 P8-07-icmp-at-host.pcap "icmp[0] == 3"; sleep 1
m1=$(sweep 1500 a-c2 10.1.3.21 1300 1400 1422 1423 1450 1472); pcap_wait
fragn=$(docker run --rm -v "$OUT:/out" "$TOOLS_IMAGE" tshark -r /out/P8-07-icmp-at-host.pcap 2>/dev/null | wc -l | tr -d ' ')
wan_mtu 9000; m2=$(sweep 9000 a-c2 10.1.3.21 1300 1400 1422 1423 1450 1472); wan_mtu 1500
{ echo "wan_ip_mtu,icmp_payload,ip_packet,result"; echo "$m1"; echo "$m2"; } > "$OUT/wan_mtu.csv"
mtu() {
  echo "method: a-c2 -> b-c3 ping -M do (DF) -s <payload>, 2 pings each; host MTU 1500; VXLAN adds 50 bytes"
  echo "        WAN = ip-mtu of the four gateways' WAN sub-interfaces (the bridge itself carries 9500)"
  echo; printf '%-12s %-13s %-11s %s\n' "WAN ip-mtu" "ICMP payload" "IP packet" result
  { echo "$m1"; echo "$m2"; } | awk -F, '{printf "%-12s %-13s %-11s %s\n",$1,$2,$3,$4}'
  echo; echo "ICMP 'destination unreachable' packets reaching a-c2 during the 1500 sweep: $fragn"
  echo "(the oversized VXLAN packet is dropped in the fabric; the host is not told)"
}
shot P8-07 mtu-over-wan a-c2 - mtu

# P8-08/09: WAN impairment with containerlab tools netem on the wan node (both ports towards site B).
lat() { hx a-c2 ping -c 50 -i 0.1 -q 10.1.3.21 2>&1 | awk -F'[ /]' '/packets transmitted/ {tx=$1; rx=$4; loss=$6} /rtt/ {printf "%s,%s,%s,%s,%s,%s\n", tx, rx, loss, $7, $8, $9}'; }
dci_state() { srlt gw-a "$NB" "Peer,Group,State,Uptime" | grep dci | awk '{printf "%s %s uptime %s; ", $1, $3, $4}'; }
b_lat=$(lat); b_st=$(dci_state)
NETEM="tools netem set -n clab-ztf-p8-wan -i eth2 --delay 30ms --jitter 5ms --loss 1"
for p in eth2 eth4; do "$CLAB" tools netem set -n clab-ztf-p8-wan -i $p --delay 30ms --jitter 5ms --loss 1 >/dev/null 2>&1; done
nshow=$("$CLAB" tools netem show -n clab-ztf-p8-wan 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'Interface|eth2|eth4' | head -4)
w_lat=$(lat); w_st=$(dci_state)
for p in eth2 eth4; do "$CLAB" tools netem reset -n clab-ztf-p8-wan -i $p >/dev/null 2>&1 || "$CLAB" tools netem set -n clab-ztf-p8-wan -i $p >/dev/null 2>&1; done
a_lat=$(lat); a_st=$(dci_state)
{ echo "phase,sent,received,loss,rtt_min_ms,rtt_avg_ms,rtt_max_ms"; echo "before,$b_lat"; echo "impaired,$w_lat"; echo "after,$a_lat"; } > "$OUT/wan_latency.csv"
netem() {
  echo "wan# containerlab $NETEM"; echo "wan# (the same for eth4, the port towards gw-b2)"
  echo "wan# containerlab tools netem show -n clab-ztf-p8-wan"; echo "$nshow" | cut -c1-118
  echo; echo "method: impairment on the WAN node's ports towards gw-b and gw-b2, one direction (egress to site B);"
  echo "        each 'netem set' replaces all values; values chosen for the lab, not taken from a real line"
}
shot P8-08 netem-impairment wan - netem
lt() {
  echo "method: a-c2 -> b-c3 ping -c 50 -i 0.1 (L3 between sites), before / with / after the impairment"
  echo; printf '%-9s %5s %5s %6s %8s %8s %8s\n' phase sent recv loss "min ms" "avg ms" "max ms"
  tail -n +2 "$OUT/wan_latency.csv" | awk -F, '{printf "%-9s %5s %5s %6s %8s %8s %8s\n",$1,$2,$3,$4,$5,$6,$7}'
  echo; echo "DCI sessions of gw-a (to gw-b and gw-b2):"; echo "  before: $b_st" | cut -c1-118; echo "  during: $w_st" | cut -c1-118; echo "  after:  $a_st" | cut -c1-118
}
shot P8-09 latency-before-after a-c2 - lt

# P8-10: one VNI over both sites.
l2() {
  echo "a-c1 (10.1.1.11, site A) and b-c1 (10.1.1.21, site B): same subnet, VLAN 101, L2VNI 10101"
  echo "a-c1# ping -c 2 10.1.1.21 -> $(hx a-c1 ping -c 2 -i 0.3 10.1.1.21 | grep 'packet loss')"
  echo "a-c1# ip neigh show 10.1.1.21 -> $(hx a-c1 ip neigh show 10.1.1.21)"
  echo; echo "leaf-a1# show network-instance mac-vrf-101 bridge-table mac-table all"
  srlt leaf-a1 "show network-instance mac-vrf-101 bridge-table mac-table all" "Address,Destination,Type" | grep -E 'Address|---|02:00:00'
  echo; echo "(destination vxlan ... vtep 10.255.1.11 = leaf-b1 in site B, reached directly, not via the gateway)"
}
shot P8-10 stretched-l2-mac-table leaf-a1 - l2

# P8-11: broadcast leaving the site. ARP from a "new" client in the stretched VNI vs. in network 02.
bcast_wan() { pcap_ports wan 5 "P8-11-$1.pcap" "eth2 eth4" "udp port 4789"; sleep 1.5; hx "$2" sh -c "ip neigh flush dev eth1; arping -c 3 -I eth1 $3 >/dev/null 2>&1" || true; pcap_wait
  merge_ports "P8-11-$1.pcap" "eth2 eth4"
  docker run --rm -v "$OUT:/out" "$TOOLS_IMAGE" tshark -r "/out/P8-11-$1.pcap" -Y "arp.opcode==1" 2>/dev/null | wc -l | tr -d ' '; }
n_l2=$(bcast_wan stretched a-c1 10.1.1.99); n_l3=$(bcast_wan l3-only a-c2 10.1.2.99)
bc() {
  echo "method: arping -c 3 for an unused address (3 ARP broadcasts), capture VXLAN on the WAN towards site B (gw-b, gw-b2)"
  echo; printf '%-44s %s\n' "a-c1 in stretched network 01 (VNI 10101)" "$n_l2 ARP requests left site A"
  printf '%-44s %s\n' "a-c2 in network 02 (exists only in site A)" "$n_l3 ARP requests left site A"
  echo; echo "VNI 10101 has three VTEPs in site B (leaf-b1, gw-b, gw-b2): ingress replication sends each broadcast three times"
}
shot P8-11 broadcast-leaves-site a-c1 - bc

# P8-12: controlled broadcast flood at a fixed rate in site A, measured at site B.
flood() { local src=$1 bdst=$2 dst=$3
  docker exec -d "$(c $src)" sh -c "timeout 6 ping -b -i 0.01 -s 64 $bdst >/dev/null 2>&1"; sleep 1
  local a b; a=$(hx $dst cat /sys/class/net/eth1/statistics/rx_packets); sleep 4; b=$(hx $dst cat /sys/class/net/eth1/statistics/rx_packets); echo $(( (b - a) / 4 )); }
pps_l2=$(flood a-c1 10.1.1.255 b-c1); sleep 3; pps_l3=$(flood a-c2 10.1.2.255 b-c3)
{ echo "case,source,target_port,rate_sent_pps,received_pps_at_site_b"; echo "stretched,a-c1 (net 01),b-c1,100,$pps_l2"; echo "l3_separated,a-c2 (net 02),b-c3,100,$pps_l3"; } > "$OUT/broadcast_flood.csv"
fl() {
  echo "method: ping -b -i 0.01 (100 broadcast packets/s, 6 s) in site A; rx packets/s on a client port in site B over 4 s"
  echo; printf '%-30s %-14s %s\n' case "sent (pps)" "received at site B (pps)"
  printf '%-30s %-14s %s\n' "stretched VNI (a-c1 -> b-c1)" 100 "$pps_l2"
  printf '%-30s %-14s %s\n' "L3-separated (a-c2 -> b-c3)" 100 "$pps_l3"
}
shot P8-12 broadcast-flood-l2-vs-l3 b-c1 - fl

# ---------------------------------------------------------------- branch
br_vrf() {
  echo "br1 (SR Linux, branch router)# show network-instance summary"
  srlt br1 "show network-instance summary" "Name,Type,Oper state,Description" | grep -vE '^(default|mgmt) '
  for v in corp guest; do echo; echo "br1# show network-instance $v $RT   (/24 and the anycast VIP)"
    rtab br1 $v | grep -E '^Prefix|^---|/24|10\.9\.100\.10'; done
  echo; echo "isolation (ping -c 3):"
  echo "  br-g1 (guest) -> a-c2 10.1.2.11 (corp, site A):  $(okc br-g1 10.1.2.11)"
  echo "  br-g1 (guest) -> br-c1 10.1.10.11 (corp, branch): $(okc br-g1 10.1.10.11)"
  echo "  br-g1 (guest) -> a-g1 10.2.1.11 (guest, site A): $(okc br-g1 10.2.1.11)"
  echo "  br-c1 (corp)  -> a-c2 10.1.2.11 (corp, site A):  $(okc br-c1 10.1.2.11)"
}
shot P8-13 branch-vrfs-isolation br1 - br_vrf

tun() {
  echo "ipsec-br# swanctl --version -> $(hx ipsec-br swanctl --version 2>&1 | head -1)   (kernel ESP, Linux xfrm)"
  echo "ipsec-br# swanctl --list-sas   (excerpt)"
  hx ipsec-br swanctl --list-sas | grep -E 'ESTABLISHED|remote .*@|AES|INSTALLED|  in |  out ' | sed -E 's/, (rekeying|expires) in [0-9]+s//g; s/  +/ /g; s/^ /  /' | cut -c1-118
  echo; echo "ipsec-br# vtysh -c 'show bgp summary'   (FRR: underlay only, one session per tunnel)"
  vtysh ipsec-br "show bgp summary" | grep -E '^(ipsec|10\.)' | awk '{printf "  %-20s AS %-6s up %-9s prefixes rx %-3s tx %-3s %s %s %s %s\n", $1, $3, $9, $10, $11, $12, $13, $14, $15}'
  echo; echo "br1# $NB   (EVPN to the four gateways, over the tunnels)"
  srlt br1 "$NB" "Peer,Group,Peer-AS,State,[Rx/Active/Tx]" | grep -E 'Peer|---|hubs'
  echo; echo "mapping: one route-based tunnel (VTI) per WAN path; both VRFs ride over it as L3VNIs (corp 50001, guest 50002), VXLAN inside ESP"
}
shot P8-14 tunnel-state ipsec-br - tun

# P8-15: tunnel overhead, MTU through the tunnel, TCP with and without MSS adjustment.
pcap ipsec-br eth1 5 P8-15-vxlan-lan.pcap "udp port 4789 and greater 1000"; pcap wan1 eth2 5 P8-15-esp-wan1.pcap "esp or udp port 4500"; sleep 1.5
hx br-c1 ping -c 1 -s 1000 10.1.2.11 >/dev/null; pcap_wait
len_of() { docker run --rm -v "$OUT:/out" "$TOOLS_IMAGE" tshark -r "/out/$1" -Y "$2" -T fields -e frame.len -e ip.len -e ip.proto 2>/dev/null | awk 'NR==1 {split($2, a, ","); split($3, b, ","); print $1, a[1], b[1]}'; }
read -r f_vx ip_vx _ <<< "$(len_of P8-15-vxlan-lan.pcap 'ip.src==10.255.2.11')"
read -r f_esp ip_esp proto_esp <<< "$(len_of P8-15-esp-wan1.pcap 'ip.src==198.51.100.2 and frame.len > 1000')"
inner=1028
pcap br1 e1-49 6 P8-15-icmp-to-br1.pcap "icmp[0] == 3"; pcap br-c1 eth1 6 P8-15-icmp-at-host.pcap "icmp[0] == 3"; sleep 1
t1=$(sweep tunnel br-c1 10.1.2.11 1300 1368 1369 1372 1400 1472); pcap_wait
icmp_br1=$(docker run --rm -v "$OUT:/out" "$TOOLS_IMAGE" tshark -r /out/P8-15-icmp-to-br1.pcap 2>/dev/null | wc -l | tr -d ' ')
icmp_host=$(docker run --rm -v "$OUT:/out" "$TOOLS_IMAGE" tshark -r /out/P8-15-icmp-at-host.pcap 2>/dev/null | wc -l | tr -d ' ')
pmtu=$(hx ipsec-br ip route get 10.255.0.11 | grep -oE 'mtu [0-9]+' || echo "mtu ?")
{ echo "path,icmp_payload,ip_packet,result"; echo "$t1"; } > "$OUT/tunnel_mtu.csv"
ip3() { local r; r=$(hx br-c1 timeout 15 iperf3 -c 10.1.2.20 -t 4 --connect-timeout 3000 "$@" 2>&1)
  echo "$r" | awk '/receiver/ && $5 > 0 {print $5" "$6", "$7" "$8; f=1} END {if (!f) print "no data (0 bytes)"}'; }
tcp_up_def=$(ip3); tcp_dn_def=$(ip3 -R); tcp_up_mss=$(ip3 -M 1356); tcp_dn_mss=$(ip3 -R -M 1356)
{ echo "direction,mss,result"; echo "branch->dc,default (1448),\"$tcp_up_def\""; echo "dc->branch,default (1448),\"$tcp_dn_def\""
  echo "branch->dc,1356,\"$tcp_up_mss\""; echo "dc->branch,1356,\"$tcp_dn_mss\""; } > "$OUT/tcp_mss.csv"
ovh() {
  echo "method: br-c1 ping -s 1000 a-c2 (inner IP packet $inner bytes); capture on br1's uplink (VXLAN) and on WAN 1 (ESP)"
  echo "  VXLAN packet on the LAN side:  IP length $ip_vx  -> VXLAN overhead $((ip_vx - inner)) bytes"
  echo "  ESP packet on WAN 1:           IP length $ip_esp (IP proto $proto_esp = ESP) -> ESP overhead $((ip_esp - ip_vx)) bytes"
  echo "  total over the host's packet:  $((ip_esp - inner)) bytes   (ipsec-br's route to leaf-a1: $pmtu)"
  echo; echo "DF ping br-c1 -> a-c2 through the tunnel (WAN MTU 1500):"
  printf '  %-13s %-11s %s\n' "ICMP payload" "IP packet" result; echo "$t1" | awk -F, '{printf "  %-13s %-11s %s\n",$2,$3,$4}'
  echo "  ICMP 'too big' sent to br1 by ipsec-br: $icmp_br1; reaching the host br-c1: $icmp_host"
  echo; echo "TCP br-c1 <-> srv-a (iperf3, 4 s; MSS 1356 = 1396 usable IP MTU - 40, set with iperf3 -M):"
  printf '  %-26s %-26s %s\n' "" "branch -> DC" "DC -> branch"
  printf '  %-26s %-26s %s\n' "default MSS (1448)" "$tcp_up_def" "$tcp_dn_def"
  printf '  %-26s %-26s %s\n' "MSS adjusted to 1356" "$tcp_up_mss" "$tcp_dn_mss"
}
shot P8-15 tunnel-overhead-mtu-mss ipsec-br - ovh

# P8-16: WAN 1 fails (100 % loss on the ISP-1 bridge, both directions), branch fails over to WAN 2, then back.
w1_route() { vtysh ipsec-br "show ip route 10.255.0.11/32" | grep -E '^\s+\*' | awk '{printf "%s %s ", $2, $4}' | tr -d ','; }
w1_down() { for p in eth1 eth2; do "$CLAB" tools netem set -n clab-ztf-p8-wan1 -i $p --loss 100 >/dev/null 2>&1; done; }
w1_up() { for p in eth1 eth2; do "$CLAB" tools netem reset -n clab-ztf-p8-wan1 -i $p >/dev/null 2>&1 || "$CLAB" tools netem set -n clab-ztf-p8-wan1 -i $p >/dev/null 2>&1; done; }
# SR Linux waits minimum-advertisement-interval (default 5 s, range 1..255) between updates to a peer;
# the branch's backup path crosses several SR Linux hops. Measured with the default, then with 1 s.
groups_of() { case "$1" in spine-*|leaf-*) echo "underlay overlay";; gw-*) echo "underlay overlay dci branch";; br1) echo "underlay hubs";; esac; }
mrai() { local n gr l; for n in $NODES; do l=""; for gr in $(groups_of $n); do l="$l
set / network-instance default protocols bgp group $gr timers minimum-advertisement-interval $1"; done; cfg $n "$l"; done; }
wan1_cycle() { local tag="$1"
  r_before=$(w1_route)
  eval "f_${tag}_down=\$(outage br-c1 10.1.2.11 wan1-fails-mrai-$tag w1_down)"
  r_during=$(w1_route); bfd_during=$(vtysh ipsec-br "show bfd peers brief" | grep -E '10\.252' | awk '{printf "%s %s; ", $3, $4}')
  eval "f_${tag}_up=\$(outage br-c1 10.1.2.11 wan1-restored-mrai-$tag w1_up)"
  wait_for 60 sh -c "docker exec $(c ipsec-br) vtysh -c 'show ip route 10.255.0.11/32' | grep -q vti1"; r_after=$(w1_route); sleep 3; }
wan1_cycle 5s
mrai 1; sleep 3
wan1_cycle 1s
f1="$f_5s_down"; f2="$f_5s_up"
outage_csv branch_failover.csv "netem loss 100% on both ports of wan1 (ISP 1); br-c1 pings a-c2 every 10 ms; BFD 3 x 300 ms on the tunnels" "$f_5s_down" "$f_5s_up" "$f_1s_down" "$f_1s_up"
fo() {
  echo "method: WAN 1 (ISP 1) loses 100 % in both directions (netem on the wan1 bridge, links stay up), then is restored;"
  echo "        br-c1 (branch, corp) pings a-c2 (site A) every 10 ms; FRR BFD 3 x 300 ms on each tunnel, BGP picks the path"
  echo; echo "SR Linux minimum-advertisement-interval 5 s (default):"; echo "$f_5s_down" | sed 's/^/  /'; echo "$f_5s_up" | sed 's/^/  /'
  echo "set to 1 s on all SR Linux BGP groups (the minimum; kept for the tests that follow):"; echo "$f_1s_down" | sed 's/^/  /'; echo "$f_1s_up" | sed 's/^/  /'
  echo; echo "ipsec-br route to leaf-a1 (10.255.0.11/32):"
  echo "  before:          $r_before"; echo "  WAN 1 down:      $r_during"; echo "  WAN 1 restored:  $r_after"
  echo "  BFD while down:  $bfd_during"
  echo; echo "backup path = WAN 2 -> ipsec-b -> site B -> DCI -> site A (WAN 1 preferred by local-pref 200 / AS-path prepend)"
}
shot P8-16 branch-wan-failover ipsec-br - fo

# P8-20: resources with all three sites running (before the failure tests).
res() { echo "docker stats --no-stream (SR Linux shows 0 here, see memory.txt) + cgroup memory"; mem_table | awk 'NR==1 || $2 > 30 {print} $2 <= 30 && NR>1 {s+=$2; n++} END {printf "%-22s %10d %8s\n", n" Linux nodes", s, "-"}'
  mem_table | awk 'NR>1 {s+=$2} END {printf "%-22s %10d\n", "total", s}'; }
mem_table > "$OUT/memory.txt"
shot P8-20 resources gw-a - res

# Failure tests: several measurements in parallel around one event.
# pings: "label:src:dst ..."; prints one outage line per ping (same format as outage()).
multi() { local dur="$1" pings="$2"; shift 2; local p l s d
  for p in $pings; do IFS=: read -r l s d <<< "$p"; docker exec -d "$(c "$s")" sh -c "ping -D -i 0.01 -W 1 -w $dur $d > /tmp/outage-$l.txt 2>&1"; done
  sleep 3; "$@"; sleep $((dur - 2))
  for p in $pings; do IFS=: read -r l s d <<< "$p"
    docker exec -i "$(c "$s")" python3 - "$l" "/tmp/outage-$l.txt" <<'PY'
import re, sys
label, path = sys.argv[1], sys.argv[2]
ts = []; sent = recv = 0
for line in open(path):
    m = re.match(r"\[(\d+\.\d+)\].*icmp_seq=(\d+)", line)
    if m: ts.append(float(m.group(1)))
    m = re.search(r"(\d+) packets transmitted, (\d+) received", line)
    if m: sent, recv = int(m.group(1)), int(m.group(2))
gap = max((b - a for a, b in zip(ts, ts[1:])), default=0.0)
lost = sent - recv
print(f"{label}: sent={sent} received={recv} lost={lost} "
      f"loss_time~{lost*10} ms (10 ms interval) largest_reply_gap={gap*1000:.0f} ms")
PY
  done; }
quiet() { "$@" >/dev/null 2>&1; }
# outage_csv for a multi-line result (bash 3.2 on macOS: no mapfile)
lines_csv() { local txt="$1" f="$2" m="$3" l; while IFS= read -r l; do if [ -n "$l" ]; then outage_csv "$f" "$m" "$l"; fi; done <<< "$txt"; }
nh_a() { rtab "$1" corp | grep -c '10.255.0.' || true; }

# P8-17a: one of site A's two gateways stopped.
b_rt=$(nh_a leaf-b1)
g1=$(multi 15 "b-c3_to_a-c2:b-c3:10.1.2.11 br-c1_to_a-c2:br-c1:10.1.2.11" quiet docker stop -t 0 "$(c gw-a)")
a_rt=$(nh_a leaf-b1)
lines_csv "$g1" site_failure.csv "docker stop -t 0 gw-a (one of site A's two gateways); pings every 10 ms"
gwf() {
  echo "method: docker stop -t 0 gw-a (its netns sidecar keeps the links up: BFD detects it); gw-a2 is left; pings every 10 ms across the event"
  echo; echo "$g1" | sed 's/^/  /'
  echo; echo "leaf-b1 VRF corp, routes with a next hop in site A (10.255.0.x): before $b_rt, after $a_rt"
  echo "gw-b# $NB   (DCI after)"; srlt gw-b "$NB" "Peer,Group,State" | grep -E 'Peer|---|dci' | sed 's/^/  /'
  echo; echo "a-c2 still reachable from site B: $(okc b-c3 10.1.2.11); from the branch: $(okc br-c1 10.1.2.11)"
}
shot P8-17a one-gateway-stopped leaf-b1 - gwf

# P8-17/18/19: the rest of site A fails (gw-a2, spine, leaf, server, IPsec concentrator).
SITE_A="gw-a2 spine-a leaf-a1 srv-a ipsec-a"
stop_site() { local n; for n in $SITE_A; do docker stop -t 0 "$(c $n)" >/dev/null 2>&1 & done; wait; }
b_rt=$(nh_a leaf-b1); vip_before=$(rtab br1 corp | grep '10.9.100.10' | awk '{print $(NF-1)}')
br_b_before=$(vtysh ipsec-br "show ip route 10.255.1.11/32" | grep -E '^\s+\*' | awk '{print $2, $4}' | tr -d ',' | head -1)
pfile=$(mktemp); t_ev=$(date -u +%Y-%m-%dT%H:%M:%S)
( probe br-c1 http://10.9.100.10/ 20 3 true > "$pfile" ) &
s1=$(multi 20 "b-c3_to_br-c1:b-c3:10.1.10.11 b-c1_to_b-c3:b-c1:10.1.3.21" stop_site)
wait; svc=$(cat "$pfile"); rm -f "$pfile"
a_rt=$(nh_a leaf-b1); vip_after=$(rtab br1 corp | grep '10.9.100.10' | awk '{print $(NF-1)}')
br_b_after=$(vtysh ipsec-br "show ip route 10.255.1.11/32" | grep -E '^\s+\*' | awk '{print $2, $4}' | tr -d ',' | head -1)
lines_csv "$s1" site_failure.csv "site A down (gw-a already stopped; gw-a2 spine-a leaf-a1 srv-a ipsec-a stopped at once); pings every 10 ms"
{ echo "metric,value"; echo "$svc" | head -1 | tr ' ' '\n' | sed 's/=/,/'; echo "before_event,\"$(echo "$svc" | sed -n 2p | sed 's/before event: *//')\""; echo "after_event,\"$(echo "$svc" | sed -n 3p | sed 's/after event: *//')\""; } > "$OUT/service_failover.csv"
sf() {
  echo "method: site A fails completely (gw-a was already down, now gw-a2, spine-a, leaf-a1, srv-a, ipsec-a, docker stop -t 0)"
  echo "        pings every 10 ms across the event (event at +3 s, 20 s window)"
  echo; echo "$s1" | sed 's/^/  /'
  echo; echo "leaf-b1 VRF corp, routes with a next hop in site A (10.255.0.x): before $b_rt, after $a_rt"
  echo "ipsec-br route to leaf-b1 (10.255.1.11): before via $br_b_before; after via $br_b_after"
  echo "leaf-b1# show network-instance corp $RT   (after, /24 only)"; rtab leaf-b1 corp | grep -E '^Prefix|^---|/24' | sed 's/^/  /'
  echo; echo "site B and branch keep working: b-c3 -> b-c1 $(okc b-c3 10.1.1.21); br-c1 -> b-c3 $(okc br-c1 10.1.3.21)"
}
shot P8-17 site-a-down leaf-b1 - sf
svf() {
  echo "service: anycast VIP 10.9.100.10 (web), announced by srv-a (site A) and srv-b (site B, AS path prepended twice)"
  echo "client:  br-c1 in the branch, a new HTTP connection every 50 ms (timeout 0.5 s), site A fails at +3 s"
  echo; echo "$svc" | sed 's/^/  /'
  echo; echo "br1 VRF corp, route to 10.9.100.10/32: before next hop $vip_before, after $vip_after"
  echo "configured: BGP from each server to its leaf (VRF corp), Type-5 into EVPN; no DNS change, no health checker"
}
shot P8-18 service-failover-between-sites br-c1 - svf
evlog=$(docker exec "$(c gw-b)" sh -c "cat /var/log/srlinux/debug/sr_bgp_mgr.log /var/log/srlinux/debug/sr_bfd_mgr.log 2>/dev/null | grep -E '10\.253\.0\.(1|3)|10\.255\.0\.2(1|2)' | grep -iE 'moved from|bfd session|went down|is down' | awk '\$1 >= \"$t_ev\"' | sort | tail -8" | sed -E 's/^([0-9T:-]{19})[^ ]* [a-z0-9-]+ [^ ]* ?sr_[a-z_]+: [^ ]*\|[A-Z]: /\1 /;s/^([0-9T:-]{19})[^ ]* [a-z0-9-]+ [^ ]* ?sr_[a-z_]+: /\1 /' | fold -w 112 | head -24 || true)
evl() { echo "event: site A stopped at ~$t_ev + 3 s (UTC); gw-b BGP/BFD log lines naming site A's gateways"; echo; echo "${evlog:-(no matching lines)}" | sed 's/^/  /'; }
shot P8-19 bgp-event-log-site-failure gw-b - evl

graph_export "$HERE/topology.clab.yml"
render_pngs
ls "$OUT"
