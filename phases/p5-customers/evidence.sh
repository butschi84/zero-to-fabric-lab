#!/usr/bin/env bash
# Phase 5 evidence: customer VRFs with overlapping addresses, CE, isolation,
# deliberate leak, shared service via firewall, register, onboarding, prefix
# limit. Run after `make deploy PHASE=p5-customers`. Writes evidence/p5-customers/.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB=ztf-p5 OUT="$HERE/../../evidence/p5-customers"
source "$HERE/../../scripts/lib.sh"
rm -f "$OUT"/P5-0[1-7]*.txt "$OUT"/P5-0[1-7]*.png "$OUT"/*.csv "$OUT"/*.pcap   # P5-00 = graph screenshot, kept
NODES="leaf1 leaf2 border1"
wait_srl spine1 spine2 $NODES
NB="show network-instance default protocols bgp neighbor"
evpn_up() { [ "$(srl "$1" "$NB" | grep -c 'established')" -ge 4 ]; }
for l in $NODES; do wait_for 240 evpn_up $l; done
has_route() { local o; o=$(srl "$1" "show network-instance $2 route-table"); [[ "$o" == *"$3"* ]]; }
wait_for 180 has_route leaf1 cust-a 192.168.10.0/24
for h in a-vm1 b-vm1 a-vm2 b-vm2 svc-dns; do gw=$(hx $h ip route show default | awk '{print $3}'); hx $h ping -c1 -W1 "$gw" >/dev/null 2>&1 || true; done
wait_for 60 has_route leaf1 cust-a 10.9.1.53
sleep 3
RT="route-table ipv4-unicast summary"
rtab() { srlt "$1" "show network-instance $2 $RT" "Prefix,Route Type,Route Owner,Next-hop (Type)"; }
who() { hx "$1" curl -s -m 1 "http://$2/" 2>/dev/null | cut -d' ' -f1 | grep . || echo FAIL; }
pingok() { hx "$1" ping -c 2 -i 0.3 -W 1 "$2" >/dev/null 2>&1 && echo OK || echo FAIL; }

same() {
  for v in a-vm1 b-vm1; do echo "$v# ip -4 addr show eth1; ping 10.0.0.1; ip neigh show 10.0.0.1"
    echo "  $(hx $v ip -4 -o addr show eth1 | awk '{print $4}')  ping gateway: $(pingok $v 10.0.0.1)  $(hx $v ip neigh show 10.0.0.1)"; done
  for t in cust-a cust-b; do echo; echo "leaf1# show network-instance $t $RT   (10.0.0.0/24 only)"
    rtab leaf1 $t | grep -E '^Prefix|^---|^10\.0\.0\.0/24|^  ' | awk 'NR<=2 || /^10\.0\.0\.0/ {p=1} p'; done
  echo; echo "who answers on 10.0.0.20 (curl, the VM prints its name):"
  echo "  from a-vm1: $(who a-vm1 10.0.0.20)    from b-vm1: $(who b-vm1 10.0.0.20)"
}
shot P5-01 two-customers-same-subnet leaf1 - same

ce() {
  echo "leaf2# show network-instance cust-a protocols bgp neighbor"
  srlt leaf2 "show network-instance cust-a protocols bgp neighbor" "Peer,Peer-AS,State,Uptime,[Rx/Active/Tx]"
  echo; echo "leaf2# show network-instance cust-a protocols bgp routes ipv4 summary   (received from the CE)"
  srlt leaf2 "show network-instance cust-a protocols bgp routes ipv4 summary" "Status,Network,Next Hop,Path Val" 2>/dev/null | grep -E 'Status|----|192\.168' || true
  echo; echo "ce-a# show bgp ipv4 unicast   (sent to and received from the fabric)"
  vtysh ce-a "show bgp ipv4 unicast" | grep -E 'Network|^\*|^ \*' | head -6
  echo; echo "leaf2# prefix limit on the CE session"
  srl leaf2 "info network-instance cust-a protocols bgp neighbor 10.11.254.1 afi-safi ipv4-unicast" | grep -E 'max-received|warning' | sed 's/^ */  /'
}
shot P5-02 ce-bgp-session leaf2 - ce

iso() {
  echo "method: cell = who answers (HTTP name) or ping result; 10.0.0.20 exists in both customers"
  printf '\n%-8s %-16s %-16s %-16s %-14s\n' "src" "10.0.0.20 (http)" "192.168.10.1 CE-A" "10.9.1.53 DNS" "MAC of 10.0.0.20"
  for v in a-vm1 b-vm1; do
    printf '%-8s %-16s %-16s %-16s %-14s\n' $v "$(who $v 10.0.0.20)" "$(pingok $v 192.168.10.1)" "$(hx $v dig +short +time=1 +tries=1 @10.9.1.53 svc.lab.example >/dev/null 2>&1 && echo OK || echo FAIL)" \
      "$(hx $v ip neigh show 10.0.0.20 | awk '{print $5}')"
  done
  echo; echo "leaf1# cust-b route table lookups"
  for p in 192.168.10.0/24 10.0.0.20; do o=$(srl leaf1 "show network-instance cust-b route-table ipv4-unicast summary" | grep -c "${p%/*}" || true); echo "  entries for $p in cust-b: $o"; done
  echo; echo "leaf1# info from state network-instance cust-b route-table ipv4-unicast statistics"
  srl leaf1 "info from state network-instance cust-b route-table ipv4-unicast statistics" | grep -E 'active-routes |total-routes ' | sed 's/^ */  /'
  echo; echo "fw# iptables -L FORWARD -v -n   (customer to customer never reaches the firewall: no route)"
  hx fw iptables -L FORWARD -v -n | tail -n 3 | cut -c1-118
}
shot P5-03 isolation-matrix a-vm1 - iso

# P5-03b: deliberate leak. leaf1 copies CE-A's 192.168.10.0/24 into cust-b.
cfg leaf1 "set / routing-policy prefix-set leak-test prefix 192.168.10.0/24 mask-length-range exact
set / routing-policy policy leak-test statement 10 match prefix-set leak-test
set / routing-policy policy leak-test statement 10 action policy-result accept
set / routing-policy policy leak-test default-action policy-result reject
set / network-instance cust-a inter-instance-policies apply-policy export-policy leak-test
set / network-instance cust-b inter-instance-policies apply-policy import-policy leak-test"; sleep 4
pcap a-vm1 eth1 6 P5-03b-leak-a-vm1.pcap "icmp"
pcap ce-a eth1 6 P5-03b-leak-ce-a.pcap "icmp"; sleep 1.5
leak_ping=$(hx b-vm1 ping -c 3 -i 0.3 -W 1 192.168.10.1 2>&1 | grep 'packet loss' || true); pcap_wait
leak_rt=$(rtab leaf1 cust-b | grep -E '^Prefix|^---|^192\.168')
cfg leaf1 "delete / network-instance cust-b inter-instance-policies
delete / network-instance cust-a inter-instance-policies
delete / routing-policy policy leak-test
delete / routing-policy prefix-set leak-test"; sleep 3
after_ping=$(pingok b-vm1 192.168.10.1)
leak() {
  echo "fault: leaf1 imports cust-a's 192.168.10.0/24 (CE-A) into VRF cust-b (inter-instance policy)"
  echo; echo "leaf1# show network-instance cust-b $RT   (leaked, owner cust-a)"; echo "$leak_rt"
  echo; echo "b-vm1# ping -c 3 192.168.10.1 -> $leak_ping"
  echo; echo "ce-a# tcpdump icmp   (B's requests reach customer A's router; it answers 10.0.0.10 in cust-a)"
  docker run --rm -v "$OUT:/out" "$TOOLS_IMAGE" tshark -r /out/P5-03b-leak-ce-a.pcap -T fields -e ip.src -e ip.dst -e icmp.type 2>/dev/null \
    | awk '{t=($3==8)?"echo request":"echo reply"; print "  "$1" -> "$2"  "t}' | sort | uniq -c | sed 's/^ */  /'
  echo; echo "a-vm1# tcpdump icmp   (the replies land at customer A's own 10.0.0.10, which never asked)"
  docker run --rm -v "$OUT:/out" "$TOOLS_IMAGE" tshark -r /out/P5-03b-leak-a-vm1.pcap -T fields -e ip.src -e ip.dst -e icmp.type 2>/dev/null \
    | awk '{t=($3==8)?"echo request":"echo reply"; print "  "$1" -> "$2"  "t}' | sort | uniq -c | sed 's/^ */  /'
  echo; echo "leak removed: b-vm1# ping 192.168.10.1 -> $after_ping"
}
shot P5-03b deliberate-leak b-vm1 - leak

# P5-04: both customers reach the shared DNS through border1 and the firewall.
hx fw iptables -Z; hx fw iptables -t nat -Z
pcap svc-dns eth1 8 P5-04-dns-at-service.pcap "udp port 53"; sleep 1.5
ra=$(hx a-vm1 dig +short +time=2 +tries=1 @10.9.1.53 svc.lab.example 2>&1 | head -1)
rb=$(hx b-vm1 dig +short +time=2 +tries=1 @10.9.1.53 svc.lab.example 2>&1 | head -1); pcap_wait
shared() {
  echo "a-vm1 (10.0.0.10, cust-a)# dig @10.9.1.53 svc.lab.example -> $ra"
  echo "b-vm1 (10.0.0.10, cust-b)# dig @10.9.1.53 svc.lab.example -> $rb"
  echo; echo "svc-dns# tcpdump udp 53   (what the service sees: two different sources)"
  docker run --rm -v "$OUT:/out" "$TOOLS_IMAGE" tshark -r /out/P5-04-dns-at-service.pcap -T fields -e ip.src -e ip.dst -e dns.flags.response 2>/dev/null \
    | awk '{print "  "$1" -> "$2"  "(($3=="1"||$3=="True")?"response":"query")}'
  echo; echo "border1# cust-a/cust-b route to the service: static 10.9.1.53/32 via the firewall"
  for t in cust-a cust-b; do echo "  $t: $(rtab border1 $t | grep '^10\.9\.1\.53' | awk '{print $1, $2, $4}')"; done
  echo; echo "fw# iptables -v -n (counters since reset): FORWARD and nat POSTROUTING"
  hx fw iptables -L FORWARD -v -n | sed -n '3,5p' | cut -c1-118
  hx fw iptables -t nat -L POSTROUTING -v -n | grep NETMAP | cut -c1-118
}
shot P5-04 shared-service-via-firewall fw - shared

reg() { echo "register read from the running state (info from state ... | as json), customer VRFs only"; echo
  for n in leaf1 leaf2 border1; do vrf_register $n | { [ $n = leaf1 ] && cat || tail -n +2; } | grep -E 'node|cust-|-1101|-1201'; done; }
shot P5-05 customer-register leaf1 - reg

# P5-06: onboard customer C on leaf1 (c-vm1 is cabled to ethernet-1/5, unconfigured).
# start clean if an earlier run already onboarded cust-c
printf 'enter candidate\ndelete / network-instance cust-c\ndelete / network-instance mac-vrf-1301\ndelete / interface irb0 subinterface 1301\ndelete / interface lo1 subinterface 13\ndelete / tunnel-interface vxlan1 vxlan-interface 1301\ndelete / tunnel-interface vxlan1 vxlan-interface 50013\ndelete / interface ethernet-1/5\ncommit now\n' | docker exec -i "$(c leaf1)" sr_cli >/dev/null 2>&1 || true
CLI=$(python3 "$REPO_ROOT/tools/onboard.py" cust-c leaf1 ethernet-1/5 10.0.0)
echo "$CLI" > "$OUT/P5-06-onboard-cust-c.cli"
t0=$(python3 -c 'import time;print(time.time())')
diffout=$(printf 'enter candidate\n%s\ndiff\ncommit now\n' "$CLI" | docker exec -i "$(c leaf1)" sr_cli 2>&1)
t1=$(python3 -c 'import time;print(time.time())')
up() { hx c-vm1 ping -c1 -W1 10.0.0.1 >/dev/null 2>&1; }
wait_for 60 up; t2=$(python3 -c 'import time;print(time.time())')
onb() {
  echo "leaf1# python3 tools/onboard.py cust-c leaf1 ethernet-1/5 10.0.0 | sr_cli (candidate, diff, commit)"
  echo "  generated: $(echo "$CLI" | wc -l | tr -d ' ') CLI lines (tools/onboard.py, same plan as all startup configs)"
  echo "  commit took $(python3 -c "print(f'{$t1-$t0:.1f}')") s; c-vm1 pings its gateway $(python3 -c "print(f'{$t2-$t0:.1f}')") s after the start"
  echo; echo "config diff (excerpt, first 14 of $(echo "$diffout" | grep -cE '^\+') added lines):"
  echo "$diffout" | grep -E '^\+' | grep -E 'network-instance|vni|address|target|evi|interface ethernet-1/5' | head -14 | cut -c1-110
  echo; echo "c-vm1 (10.0.0.10, cust-c)# ping 10.0.0.1 -> $(pingok c-vm1 10.0.0.1); curl 10.0.0.20 -> $(who c-vm1 10.0.0.20)"
}
shot P5-06 onboard-customer-c leaf1 - onb

# P5-07: prefix limit. ce-a announces ten more networks (12 > limit 5).
# the summary table lists the peer only while it has a row; a torn-down session
# leaves just header and separator, so look for the peer address explicitly
st() { local r; r=$(srlt leaf2 "show network-instance cust-a protocols bgp neighbor" "Peer,State,Uptime,[Rx/Active/Tx]" | grep -F 10.11.254.1 | tail -1 || true)
  [ -z "$r" ] && r="no row (session torn down by the prefix limit, not established)"; echo "$r"; }
before=$(st)
for i in $(seq 20 29); do docker exec "$(c ce-a)" vtysh -c "configure terminal" -c "ip route 192.168.$i.0/24 Null0" -c "router bgp 64611" -c "address-family ipv4 unicast" -c "network 192.168.$i.0/24" >/dev/null; done
sleep 8; after=$(st)
ev=$(docker exec "$(c leaf2)" sh -c "grep -ih 'prefix' /var/log/srlinux/debug/sr_bgp_mgr.log /var/log/srlinux/file/* 2>/dev/null | grep -iE 'limit|maximum|exceed' | tail -1" | sed -E 's/^([0-9T:-]{19})[^ ]* leaf2 sr_bgp_mgr: [^W]*W: /\1 /' | fold -w 110 || true)
cel=$(vtysh ce-a "show bgp neighbors 10.11.254.0" | grep -iE 'Last reset|BGP state|Notification' | head -3 | sed 's/^ */  /')
for i in $(seq 20 29); do docker exec "$(c ce-a)" vtysh -c "configure terminal" -c "router bgp 64611" -c "address-family ipv4 unicast" -c "no network 192.168.$i.0/24" -c "exit-address-family" -c "exit" -c "no ip route 192.168.$i.0/24 Null0" >/dev/null; done
sleep 5; restored_wait=$(st)
pl() {
  echo "method: ce-a adds 10 networks (192.168.20-29.0/24) to its 2; leaf2 allows 5 (warning at 80 %)"
  echo; echo "leaf2 session to ce-a before:  $before"; echo "leaf2 session to ce-a after:   $after"
  echo; echo "ce-a# show bgp neighbors 10.11.254.0 (excerpt; the leaf tears the session down, it comes back, is torn down again)"; echo "$cel"
  [ -n "$ev" ] && { echo; echo "leaf2 log:"; echo "$ev" | sed 's/^/  /'; }
  echo; echo "extra networks removed on ce-a, 5 s later: $restored_wait"
}
shot P5-07 prefix-limit leaf2 - pl

mem_table > "$OUT/memory.txt"
graph_export "$HERE/topology.clab.yml"
render_pngs
ls "$OUT"
