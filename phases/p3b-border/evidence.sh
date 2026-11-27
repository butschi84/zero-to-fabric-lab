#!/usr/bin/env bash
# Phase 3b evidence: border leafs, firewall, WAN, Type-5 default, shared services.
# Run after `make deploy PHASE=p3b-border`. Writes evidence/p3b-border/.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB=ztf-p3b OUT="$HERE/../../evidence/p3b-border"
source "$HERE/../../scripts/lib.sh"
rm -f "$OUT"/P3b-0[1-5]*.txt "$OUT"/P3b-0[1-5]*.png "$OUT"/*.csv   # P3b-06 = graph screenshot, kept
NODES="leaf1 leaf3 border1 border2"
wait_srl spine1 spine2 $NODES
NB="show network-instance default protocols bgp neighbor"
evpn_up() { [ "$(srl "$1" "$NB" | grep -c 'established')" -ge 4 ]; }
for l in $NODES; do wait_for 240 evpn_up $l; done
has_route() { local o; o=$(srl "$1" "show network-instance $2 route-table"); [[ "$o" == *"$3"* ]]; }
wait_for 180 has_route leaf1 corp 0.0.0.0/0
for h in corp1 guest1 svc-dns mgmt3; do gw=$(hx $h ip route show default | awk '{print $3}'); hx $h ping -c1 -W1 "$gw" >/dev/null 2>&1 || true; done
wait_for 60 has_route leaf1 corp 10.9.1.53
sleep 3
RT="route-table ipv4-unicast summary"
rtab() { srlt "$1" "show network-instance $2 $RT" "Prefix,Route Type,Route Owner,Next-hop (Type)"; }

T5="show network-instance default protocols bgp routes evpn route-type 5 summary"
defr() {
  echo "leaf1# $T5   (0.0.0.0/0 only)"
  srlt leaf1 "$T5" "Status,Route-distinguisher,IP-address,Next-Hop,Label" | grep -E 'Status|----|0\.0\.0\.0/0' | grep -vE '^\*  '
  for v in "leaf1 corp" "leaf1 guest" "leaf1 shared" "leaf3 mgmt-net"; do
    set -- $v; echo; echo "$1# show network-instance $2 route-table ... 0.0.0.0/0"
    rtab $1 $2 | grep -E '^Prefix|^---|^0\.0\.0\.0|^  ' | awk 'NR<=2 || /^0\.0\.0\.0/ {p=1} p' | sed -n '1,5p'
  done
}
shot P3b-01 type5-default-per-vrf leaf1 - defr

# P3b-02: firewall rules and counters after traffic to the WAN.
hx fw iptables -Z
hx corp1 ping -c 3 -i 0.3 198.51.100.1 >/dev/null 2>&1 || true
hx guest1 ping -c 2 -i 0.3 198.51.100.1 >/dev/null 2>&1 || true
hx guest1 ping -c 2 -i 0.3 -W 1 10.1.1.11 >/dev/null 2>&1 || true
fwr() {
  echo "corp1# ping -c 3 198.51.100.1 (WAN);  guest1# ping -c 2 198.51.100.1;  guest1# ping -c 2 10.1.1.11 (corp)"
  echo; echo "fw# iptables -L FORWARD / TENANT-RULES -v -n   (counters since reset)"
  hx fw iptables -L FORWARD -v -n | sed -n '1,5p' | cut -c1-118
  hx fw iptables -L TENANT-RULES -v -n | cut -c1-118
  echo; echo "fw# vtysh -c 'show ip route 0.0.0.0/0'  (learned from the WAN router)"
  vtysh fw "show ip route 0.0.0.0/0" | grep -E 'Known via|via 10' | head -2
}
shot P3b-02 firewall-rules-counters fw - fwr

leakcfg() {
  echo "leaf1# info routing-policy policy leak-shared-to-corp ; inter-instance-policies"
  srl leaf1 "info routing-policy prefix-set leak-shared-to-corp" | grep -E 'ip-prefix|mask-length' | sed 's/^ */  /'
  for v in shared corp; do echo "  network-instance $v: $(srl leaf1 "info network-instance $v inter-instance-policies" | grep -E 'export-policy|import-policy' | sed 's/^ *//')"; done
  echo; echo "leaf1# show network-instance corp $RT   (10.9.x leaked from VRF shared)"
  rtab leaf1 corp | grep -E '^Prefix|^---|^10\.9\.1'
  echo; echo "leaf3# show network-instance shared $RT   (corp prefixes leaked back)"
  rtab leaf3 shared | grep -E '^Prefix|^---|^10\.1\.1'
  echo; echo "border1# show network-instance shared $RT | grep 10.1.  (leaked routes stay local)"
  echo "  $(rtab border1 shared | grep -c '^10\.1\.' || true) entries"
}
shot P3b-03 route-leaking leaf1 - leakcfg

# P3b-04: shared DNS from corp (variant A, leaked) and guest (variant B, firewall).
hx fw iptables -Z
svc() {
  for h in corp1 guest1; do
    echo "$h# dig +short @10.9.1.53 svc.lab.example -> $(hx $h dig +short +time=2 +tries=1 @10.9.1.53 svc.lab.example 2>&1 | head -1)"
    echo "$h# ping -c 3 10.9.1.53 -> $(hx $h ping -c 3 -i 0.3 10.9.1.53 2>&1 | grep 'packet loss' || true)"
  done
  echo; echo "guest1# traceroute -I -n 10.9.1.53   while fw captures on its guest sub-interfaces"
  docker exec -d "$(c fw)" timeout 5 tcpdump -ni any -v "icmp and src 10.2.1.11 and dst 10.9.1.53" -w /tmp/p3b04.pcap; sleep 1
  hx guest1 traceroute -I -n -q 1 -w 1 -m 4 10.9.1.53 2>&1 | tail -n +2 | sed 's/^/  /'
  sleep 5; echo "fw# tcpdump -v   (seq 2 was sent with TTL 2; seen entering (253) and leaving (252) the fw)"
  hx fw sh -c 'tcpdump -nv -r /tmp/p3b04.pcap 2>/dev/null' | paste - - \
    | sed -E 's/.*ttl ([0-9]+).* ([0-9.]+) > ([0-9.]+): ICMP echo request, id [0-9]+, seq ([0-9]+).*/  seq \4  \2 > \3  ttl at fw \1/' | sort -u | head -3
  echo; echo "fw# iptables -L TENANT-RULES -v -n   (counters since reset: guest passes the firewall, corp does not)"
  hx fw iptables -L TENANT-RULES -v -n | cut -c1-118 | sed -n '3,6p'
}
shot P3b-04 shared-service-dns corp1 - svc

# P3b-05: WAN failure. The firewall's WAN link goes down; the WAN default
# disappears from the firewall, the borders and the fabric. Polling leaf1's
# corp route table (one sr_cli call per poll, ~0.3-0.6 s resolution).
poll_gone() { local t0=$1 want=$2; while :; do
    o=$(srl leaf1 "show network-instance corp route-table ipv4-unicast summary" 2>/dev/null)
    if { [ "$want" = gone ] && [[ "$o" != *"0.0.0.0/0"* ]]; } || { [ "$want" = back ] && [[ "$o" == *"0.0.0.0/0"* ]]; }; then
      python3 -c "import time;print(f'{time.time()-$t0:.1f}')"; return; fi
    [ "$(python3 -c "import time;print(int(time.time()-$t0))")" -gt 120 ] && { echo timeout; return; }
  done; }
before=$(rtab leaf1 corp | grep -E '^Prefix|^---|^0\.0\.0\.0|^  ' | sed -n '1,4p')
echo "run,event,seconds_until_leaf1_corp_route_table_changed,method" > "$OUT/wan_failover.csv"
M='"ip link set eth3 down|up on fw; poll leaf1 VRF corp route table via sr_cli, ~0.5 s resolution"'
for run in 1 2 3 4 5; do
  t0=$(python3 -c 'import time;print(time.time())'); hx fw ip link set eth3 down; d=$(poll_gone "$t0" gone)
  if [ $run = 1 ]; then
    during=$(rtab leaf1 corp | grep -cE '^0\.0\.0\.0' || true)
    during_ping=$(hx corp1 ping -c 2 -W 1 198.51.100.1 2>&1 | grep -E 'From|packet loss' | head -1 || true)
  fi
  sleep 3
  t1=$(python3 -c 'import time;print(time.time())'); hx fw ip link set eth3 up; u=$(poll_gone "$t1" back)
  echo "$run,WAN down -> 0/0 withdrawn,$d,$M" >> "$OUT/wan_failover.csv"
  echo "$run,WAN up -> 0/0 back,$u,$M" >> "$OUT/wan_failover.csv"
  sleep 8
done
after=$(hx corp1 ping -c 2 -W 1 198.51.100.1 2>&1 | grep 'packet loss' || true)
stats() { grep "$1" "$OUT/wan_failover.csv" | cut -d, -f3 | sort -n | awk '{a[NR]=$1} END {printf "min %.1f  median %.1f  max %.1f s (n=%d)", a[1], a[int((NR+1)/2)], a[NR], NR}'; }
down=$(stats withdrawn); up=$(stats back)
wanf() {
  echo "method: fw 'ip link set eth3 down' (WAN link), then poll leaf1 VRF corp route table until 0/0 is gone;"
  echo "        same for 'up'; 5 runs. Poll resolution ~0.5 s (one sr_cli call per poll). Lab times, not hardware."
  echo; echo "before:"; echo "$before" | sed 's/^/  /'
  echo; echo "WAN down -> 0.0.0.0/0 gone from leaf1 corp: $down"
  echo "during the outage (entries left: $during): corp1# ping 198.51.100.1 -> $during_ping"
  echo "WAN up   -> 0.0.0.0/0 back in leaf1 corp: $up"
  echo "corp1# ping 198.51.100.1 -> $after"
  echo; echo "chain: WAN router -(eBGP default-originate)-> fw -(eBGP per VRF, 0/0 only)-> border1/2 -(EVPN Type-5)-> leafs"
}
shot P3b-05 wan-failure-default-withdrawn leaf1 - wanf

mem_table > "$OUT/memory.txt"
graph_export "$HERE/topology.clab.yml"
render_pngs
ls "$OUT"
