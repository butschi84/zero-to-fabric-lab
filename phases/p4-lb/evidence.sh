#!/usr/bin/env bash
# Phase 4 evidence: anycast VIP via BGP (ECMP), HAProxy + keepalived, failures.
# Run after `make deploy PHASE=p4-lb`. Writes evidence/p4-lb/.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB=ztf-p4 OUT="$HERE/../../evidence/p4-lb"
source "$HERE/../../scripts/lib.sh"
rm -f "$OUT"/P4-0[1-5]*.txt "$OUT"/P4-0[1-5]*.png "$OUT"/*.csv "$OUT"/*.pcap   # P4-06 = graph screenshot, kept
LEAFS="leaf1 leaf2 leaf3"
wait_srl spine1 spine2 $LEAFS
NB="show network-instance default protocols bgp neighbor"
evpn_up() { [ "$(srl "$1" "$NB" | grep -c 'established')" -ge 4 ]; }
for l in $LEAFS; do wait_for 240 evpn_up $l; done
vip_ecmp() { local o; o=$(srl leaf1 "show network-instance corp route-table ipv4-unicast prefix 10.9.100.10/32"); [[ "$o" == *10.255.0.12* && "$o" == *10.255.0.13* ]]; }
wait_for 180 vip_ecmp
web_up() { hx corp1 curl -s -m 1 http://10.9.1.100/ | grep -q srv; }
wait_for 60 web_up
URL=http://10.9.100.10/ LB=http://10.9.1.100/
RTS="route-table ipv4-unicast prefix 10.9.100.10/32"
vipt() { srlt "$1" "show network-instance $2 $RTS" "Prefix,Route Type,Route Owner,Next-hop (Type)" | grep -vE '^$'; }

vip() {
  echo "leaf1# show network-instance corp $RTS   (VIP via two service leafs)"; vipt leaf1 corp
  echo; echo "leaf3# show network-instance shared $RTS   (two local servers)"; vipt leaf3 shared
  echo; echo "leaf3# show network-instance shared protocols bgp neighbor   (servers, eBGP)"
  srlt leaf3 "show network-instance shared protocols bgp neighbor" "Peer,Peer-AS,State,Uptime,[Rx/Active/Tx]"
  echo; echo "srv2# vtysh -c 'show bgp ipv4 unicast 10.9.100.10/32'   (what a server announces)"
  vtysh srv2 "show bgp ipv4 unicast 10.9.100.10/32" | grep -E 'Local|0.0.0.0 from|Advertised' | head -3
}
shot P4-01 anycast-vip-routes leaf1 - vip

# one batch of 100 requests per client feeds both the shot and the CSV (they used to be two batches)
for cl in corp1 corp2; do
  hx $cl sh -c 'for i in $(seq 100); do curl -s -m 1 http://10.9.100.10/ || echo "FAILED -"; done' | sort | uniq -c | awk -v c=$cl '{print c, $2, $3, $1}'
done > "$OUT/.vip_batch"
req() {
  echo "method: 100 HTTP requests (new TCP connection each) to the anycast VIP 10.9.100.10 per client;"
  echo "        each server answers with its hostname and MAC. Fabric ECMP: leaf1 -> leaf2|leaf3, then leaf3 -> srv2|srv3"
  echo
  printf '%-8s %-26s %s\n' client "server (MAC)" answers
  awk '{printf "%-8s %-26s %s\n", $1, $2" ("$3")", $4}' "$OUT/.vip_batch"
  echo; echo "leaf1# info system load-balancing hash-options   (empty = defaults: 5-tuple)"
  srl leaf1 "info from state system load-balancing hash-options" | grep -vE '^ *(system|load-balancing|hash-options) \{|^ *\}' | sed 's/^ */  /' | head -8
}
shot P4-02 vip-100-requests corp1 - req
{ echo "client,server,answers_of_100"; awk '{print $1","$2","$4}' "$OUT/.vip_batch"; } > "$OUT/vip_distribution.csv"
rm -f "$OUT/.vip_batch"

# P4-03: HAProxy stats and keepalived state; VRRP adverts cross the fabric.
pcap lb2 eth1 4 P4-03-vrrp.pcap "vrrp"; sleep 4.5; pcap_wait
hp() {
  echo "lb1# curl -s 'http://10.9.1.21:8404/stats;csv'   (HAProxy status page, selected columns)"
  hx corp1 curl -s "http://10.9.1.21:8404/stats;csv" | python3 -c '
import csv, sys
rows = list(csv.DictReader(l.lstrip("# ") for l in sys.stdin))
cols = ["pxname", "svname", "status", "check_status", "stot", "lastchg"]
print("  " + "  ".join(f"{c:12}" for c in cols))
for r in rows:
    if r["pxname"] == "servers":
        print("  " + "  ".join(f"{r.get(c, ""):12}" for c in cols))'
  echo; echo "keepalived (VRRP VIP 10.9.1.100) - who holds the VIP:"
  for n in lb1 lb2; do echo "  $n: $(hx $n ip -4 -o addr show eth1 | awk '{print $4}' | tr '\n' ' ')$(hx $n ip -4 -o addr show eth1 | grep -q 10.9.1.100 && echo '-> MASTER' || echo '-> BACKUP')"; done
  echo; echo "lb2# tcpdump vrrp, 4 s on eth1   (adverts from lb1 on leaf2 reach lb2 on leaf3 through EVPN)"
  docker run --rm -v "$OUT:/out" "$TOOLS_IMAGE" tshark -r /out/P4-03-vrrp.pcap -T fields -e frame.time_relative -e ip.src -e ip.dst -e vrrp.virt_rtr_id -e vrrp.prio -e vrrp.ip_addr 2>/dev/null \
    | awk '{printf "  t=%.1fs  %s -> %s  VRID %s  prio %s  VIP %s\n", $1, $2, $3, $4, $5, $6}' | head -5
  echo; echo "corp1# curl http://10.9.1.100/ x4   (HAProxy round robin)"; for i in 1 2 3 4; do echo "  $(hx corp1 curl -s -m 1 $LB)"; done
}
shot P4-03 haproxy-keepalived-state lb1 - hp

# P4-04: server failure, two variants. srv2's announcement goes away.
graceful() { vtysh srv2 "configure terminal" >/dev/null; docker exec "$(c srv2)" vtysh -c "configure terminal" -c "router bgp 65412" -c "neighbor 10.9.1.1 shutdown"; }
restore_g() { docker exec "$(c srv2)" vtysh -c "configure terminal" -c "router bgp 65412" -c "no neighbor 10.9.1.1 shutdown"; }
a=$(probe corp1 $URL 15 3 graceful); vip_after=$(vipt leaf3 shared | grep -E 'indirect|direct' | sed 's/^/    /')
restore_g; wait_for 60 vip_ecmp; sleep 5
b=$(probe corp1 $URL 20 3 docker pause "$(c srv2)")
docker unpause "$(c srv2)"; sleep 15; wait_for 60 vip_ecmp
{ echo "variant,method,summary"
  echo "A,\"srv2 BGP neighbor shutdown (maintenance)\",\"$(echo "$a" | head -1)\""
  echo "B,\"docker pause srv2 (server hangs, link stays up; BGP hold time)\",\"$(echo "$b" | head -1)\""; } > "$OUT/server_failover.csv"
srvf() {
  echo "method: corp1 opens a new HTTP connection to the VIP every 50 ms (timeout 0.5 s); event at t=3 s on srv2"
  echo; echo "A) srv2: 'neighbor 10.9.1.1 shutdown' (route withdrawn on purpose), 15 s:"; echo "$a" | sed 's/^/  /'
  echo "  leaf3 shared VIP next hops afterwards:"; echo "$vip_after"
  echo; echo "B) docker pause srv2 (hangs; link up, no BGP message; hold time 9 s), 20 s:"; echo "$b" | sed 's/^/  /'
  echo; echo "srv2# vtysh -c 'show bgp neighbors 10.9.1.1' | grep -i hold"; vtysh srv2 "show bgp neighbors 10.9.1.1" | grep -iE 'hold time' | head -2 | sed 's/^ */  /'
}
shot P4-04 server-failure srv2 - srvf

# P4-05: active balancer (VRRP master lb1) fails: docker pause = the box hangs.
echo "run,event,summary,lb2_holds_vip_after_s" > "$OUT/lb_failover.csv"
# pause lb1, then measure when lb2 has taken the VIP (keepalived's part of the outage)
pause_lb1() { local t0; t0=$(python3 -c 'import time;print(time.time())'); docker pause "$(c lb1)"
  until hx lb2 ip -4 -o addr show eth1 | grep -q 10.9.1.100; do sleep 0.1; done
  python3 -c "import time;print(f'{time.time()-$t0:.1f}')" > "$OUT/.vrrp_t"; }
for run in 1 2 3; do
  r1=$(probe corp1 $LB 15 3 pause_lb1); vt=$(cat "$OUT/.vrrp_t"); rm -f "$OUT/.vrrp_t"
  if [ $run = 1 ]; then
    c1="$r1"
    holder=$(hx lb2 ip -4 -o addr show eth1 | grep -q 10.9.1.100 && echo "lb2 holds 10.9.1.100" || echo "lb2 does NOT hold the VIP")
    arp_l2=$(srlt leaf2 "show arpnd arp-entries interface irb0 subinterface 901" "Neighbor,Link layer address,Origin" 2>/dev/null | grep -E 'Neighbor|10\.9\.1\.100' || true)
  fi
  r2=$(probe corp1 $LB 12 3 docker unpause "$(c lb1)")
  [ $run = 1 ] && c2="$r2"
  echo "$run,\"docker pause lb1 (VRRP master)\",\"$(echo "$r1" | head -1)\",$vt" >> "$OUT/lb_failover.csv"
  echo "$run,\"docker unpause lb1 (preempts back)\",\"$(echo "$r2" | head -1)\"," >> "$OUT/lb_failover.csv"
  sleep 5
done
runs=$(grep '"docker pause lb1' "$OUT/lb_failover.csv" | sed -E 's/.*failed=([0-9]+) largest_gap_s=([0-9.]+).*,([0-9.]+)$/gap \2 s (VIP on lb2 after \3 s)/' | paste -sd';' -)
lbf() {
  echo "method: corp1 -> http://10.9.1.100/ (VRRP VIP) every 50 ms, timeout 0.5 s; event at t=3 s. VRRP advert 1 s, priority 150/100"
  echo; echo "docker pause lb1 (master hangs), 15 s:"; echo "$c1" | sed 's/^/  /'
  echo "  afterwards: $holder"
  echo "  leaf2 ARP entry for the VIP (MAC moved to lb2 02:00:00:09:01:22, learned via EVPN):"; echo "$arp_l2" | sed 's/^/    /'
  echo "  all 3 runs (pause): $runs"
  echo; echo "docker unpause lb1 (preempts the VIP back), 12 s:"; echo "$c2" | sed 's/^/  /' | head -2
}
shot P4-05 balancer-failover lb1 - lbf

mem_table > "$OUT/memory.txt"
graph_export "$HERE/topology.clab.yml"
render_pngs
ls "$OUT"
