#!/usr/bin/env bash
# Phase 6 evidence: EVPN multihoming (ESI, LACP, DF, aliasing) and failure tests.
# Run after `make deploy PHASE=p6-multihoming`. Writes evidence/p6-multihoming/.
# The LAST test stops the leaf1 container; run `make destroy` afterwards.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB=ztf-p6 OUT="$HERE/../../evidence/p6-multihoming"
source "$HERE/../../scripts/lib.sh"
rm -f "$OUT"/P6-0[1-5]*.txt "$OUT"/P6-0[1-5]*.png "$OUT"/*.csv   # P6-00 = graph screenshot, kept
LEAFS="leaf1 leaf2 leaf3"
wait_srl spine1 spine2 $LEAFS
NB="show network-instance default protocols bgp neighbor"
evpn_up() { [ "$(srl "$1" "$NB" | grep -c 'established')" -ge 4 ]; }
all_up() { for l in $LEAFS; do evpn_up $l || return 1; done; }
wait_for 240 all_up
SM=02:00:00:01:01:50 ESI=00:11:22:33:44:55:66:77:88:01
T1="show network-instance default protocols bgp routes evpn route-type 1 summary"
T4="show network-instance default protocols bgp routes evpn route-type 4 summary"
es_peers() { srl leaf3 "$T1" | grep 'u\*>' | grep "$ESI" | awk -F'|' '{print $7}' | tr -d ' ' | sort -u | tr '\n' ' '; }
es_ready() { [ "$(es_peers | wc -w)" -ge 2 ]; }
wait_for 120 es_ready
hx cl3 ping -c 3 -W 1 10.1.1.50 >/dev/null 2>&1 || true; sleep 2

es() {
  echo "leaf1# show system network-instance ethernet-segments detail   (excerpt)"
  srl leaf1 "show system network-instance ethernet-segments detail" | grep -E 'Name  |ESI  |Multi-homing|Interface  |DF Election|Candidates|mac-vrf' | sed 's/^ */  /'
  echo; echo "leaf3# $T1   (A-D per EVI tag 0, per ES tag 4294967295)"
  printf '%-7s %-17s %-31s %-11s %s\n' Status RD ESI Tag-ID Next-Hop
  srl leaf3 "$T1" | grep 'u\*>' | awk -F'|' '{gsub(/ /,""); printf "%-7s %-17s %-31s %-11s %s\n", $2, $3, $4, $5, $7}'
  echo; echo "leaf1# $T4   (ES route, used for the DF election)"
  srlt leaf1 "$T4" "Status,Route-distinguisher,ESI,originating-router" 2>/dev/null | grep -E 'Status|---|u\*>|\*>' | head -5
  echo; echo "leaf3# mac-table mac $SM   (aliasing: destination is the ESI, not one VTEP)"
  srl leaf3 "show network-instance mac-vrf-101 bridge-table mac-table mac $SM" | grep -E 'Destination|Type  ' | sed 's/^ */  /'
}
shot P6-01 ethernet-segment-df-routes leaf1 - es

lacp() {
  for l in leaf1 leaf2; do echo "$l# show lag lag1 lacp-state"
    srlt $l "show lag lag1 lacp-state" "Members,Oper state,Timeout,State,System Id,Oper key,Partner Id" | sed 's/^/  /'; done
  echo; echo "srv-mh# grep ... /proc/net/bonding/bond0   (one bond, one partner: both leafs show the same system id)"
  hx srv-mh grep -E 'Bonding Mode|Transmit Hash|LACP rate|Slave Interface|Aggregator ID|Partner Mac|MII Status' /proc/net/bonding/bond0 | sed 's/^\t*/  /' | head -14
}
shot P6-02 lag-lacp-state leaf1 - lacp

# P6-03/P6-04: failures, measured from cl3 (leaf3) -> srv-mh, ping every 10 ms.
CSV=failover.csv; RTB=""
state() {
  local u o; u=$(srl leaf3 "show network-instance default route-table ipv4-unicast prefix 10.255.0.11/32" 2>/dev/null | grep -c '10.255.0.11/32' || true)
  o=$(srl spine1 "$NB" | grep '10.255.0.11 ' | awk -F'|' '{gsub(/ /,"",$7); print $7}')
  echo "Type-1 next hops: $(es_peers)| leaf1 loopback in leaf3 underlay: $([ "$u" -gt 0 ] && echo yes || echo NO) | spine1 overlay session to leaf1: $o"; }
rec_state() { RTB+="$1"$'\n'"  before: $2"$'\n'"  12 s in: $3"$'\n'; }
quiet() { "$@" >/dev/null 2>&1; }
# event that also snapshots the state 9 s later (outage() keeps pinging 13 s)
ev() { "$@" >/dev/null 2>&1; ( sleep 9; state > "$OUT/.during" ) & }
recover() { wait_for 240 all_up; wait_for 120 es_ready; sleep 5; }

b=$(state); l1=$(outage cl3 10.1.1.50 "leaf1-access-link-admin-down" ev cfg leaf1 "set / interface ethernet-1/1 admin-state disable"); wait
rec_state "1 leaf1 access link admin down" "$b" "$(cat "$OUT/.during")"; outage_csv $CSV "set interface ethernet-1/1 admin-state disable on leaf1 (LAG member)" "$l1"
cfg leaf1 "set / interface ethernet-1/1 admin-state enable"; recover

b=$(state); l2=$(outage cl3 10.1.1.50 "spine1-hangs-docker-pause" ev docker pause "$(c spine1)"); wait
rec_state "2 spine1 hangs (docker pause)" "$b" "$(cat "$OUT/.during")"; outage_csv $CSV "docker pause spine1 (no link-down, BFD 3x1 s detects)" "$l2"
docker unpause "$(c spine1)"; recover

b=$(state); t_ev=$(date -u +%Y-%m-%dT%H:%M:%S)
l3=$(outage cl3 10.1.1.50 "leaf1-hangs-docker-pause" ev docker pause "$(c leaf1)"); wait
rec_state "3 leaf1 hangs (docker pause)" "$b" "$(cat "$OUT/.during")"; outage_csv $CSV "docker pause leaf1 (links stay up; LACP 3x1 s and BFD 3x1 s detect)" "$l3"
sleep 2
clean() { sed -E 's/^([0-9T:-]{19})[^ ]* [a-z0-9]+ [^ ]* ?sr_[a-z_]+: [^W]*W: /\1 /;s/^([0-9T:-]{19})[^ ]* [a-z0-9]+ [^ ]* ?sr_[a-z_]+: [^ ]*\|[A-Z]: /\1 /' | fold -w 112; }
ev_spine=$(docker exec "$(c spine1)" sh -c "cat /var/log/srlinux/debug/sr_bgp_mgr.log /var/log/srlinux/debug/sr_bfd_mgr.log 2>/dev/null | grep -E '10\.254\.1\.1|10\.255\.0\.11' | awk '\$1 >= \"$t_ev\"' | sort | tail -3" | clean || true)
ev_leaf3=$(docker exec "$(c leaf3)" sh -c "cat /var/log/srlinux/debug/sr_bgp_mgr.log 2>/dev/null | grep -E 'moved from|10\.255\.0\.11' | awk '\$1 >= \"$t_ev\"' | tail -2" | clean || true)
docker unpause "$(c leaf1)"; recover

b=$(state); l4=$(outage cl3 10.1.1.50 "leaf1-stopped-docker-stop" ev docker stop -t 0 "$(c leaf1)"); wait
rec_state "4 leaf1 stopped (docker stop: all its links go down)" "$b" "$(cat "$OUT/.during")"; rm -f "$OUT/.during"; outage_csv $CSV "docker stop -t 0 leaf1 (node gone, links down on all peers)" "$l4"

fail() {
  echo "method: cl3 (leaf3) ping -i 0.01 srv-mh (dual-homed leaf1+leaf2), event after 3 s, 15 s total;"
  echo "        loss_ms = lost x 10 ms. One run per row. Lab times (vSR Linux, BFD/LACP 1 s), not hardware."
  echo
  printf '%-34s %6s %5s %8s %8s\n' failure sent lost loss_ms max_gap
  tail -n +2 "$OUT/$CSV" | awk -F, '{printf "%-34s %6s %5s %8s %8s\n", $1, $2, $4, $5, $6}'
  echo; echo "not measured here: border failure (see phase 3b, WAN/default withdrawal)"
}
shot P6-03 failure-table cl3 - fail

rts() { echo "$RTB"; }
rts() { echo "$RTB"; echo "server MAC $SM on leaf3 -> $(srl leaf3 "show network-instance mac-vrf-101 bridge-table mac-table mac $SM" 2>/dev/null | grep Destination | sed 's/.*Destination *: //')"; }
shot P6-04 routes-before-during leaf3 "Type-1 (ES) next hops, leaf1 loopback reachability, overlay session (before / 12 s into each failure)" rts

evl() {
  echo "event: docker pause leaf1 at $t_ev (UTC); BGP/BFD log lines after that"
  echo; echo "spine1 (underlay session to leaf1, BFD):"; echo "${ev_spine:-(no matching lines)}" | sed 's/^/  /'
  echo; echo "leaf3 (BGP log, lines naming leaf1 or a state change):"; echo "${ev_leaf3:-(none: the overlay session via the route reflectors stays up, hold time 90 s)}" | sed 's/^/  /'
}
shot P6-05 bgp-event-log spine1 - evl

mem_table > "$OUT/memory.txt"
graph_export "$HERE/topology.clab.yml"
render_pngs
ls "$OUT"
