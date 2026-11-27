#!/usr/bin/env bash
# Phase 1 evidence: eBGP underlay, ECMP, BFD, spine failure.
# Run after `make deploy PHASE=p1-underlay`. Writes evidence/p1-underlay/.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB=ztf-p1 OUT="$HERE/../../evidence/p1-underlay"
source "$HERE/../../scripts/lib.sh"
rm -f "$OUT"/P1-*.txt "$OUT"/P1-*.png
wait_srl spine1 spine2 leaf1 leaf2
established() { [ "$(srl "$1" 'show network-instance default protocols bgp neighbor' | grep -cE '\| established ')" -ge "$2" ]; }
wait_for 180 established leaf1 2; wait_for 180 established leaf2 2

NB="show network-instance default protocols bgp neighbor"
COLS="Peer,Group,Flags,Peer-AS,State,Uptime,AFI/SAFI,[Rx/Active/Tx]"
both_nb() { echo "leaf1# $NB"; srlt leaf1 "$NB" "$COLS"; echo; echo "spine1# $NB"; srlt spine1 "$NB" "$COLS"; }
shot P1-01 bgp-neighbors leaf1 - both_nb

asn_table() {
  printf '%-8s %-8s %-13s %s\n' node asn loopback role
  local f; for f in "$HERE"/configs/*.cli; do
    n=$(basename "$f" .cli)
    asn=$(awk '/protocols bgp autonomous-system/{print $NF}' "$f")
    lo=$(awk '/system0 subinterface 0 ipv4 address/{print $NF}' "$f")
    printf '%-8s %-8s %-13s %s\n' "$n" "$asn" "$lo" "$([[ $n == spine* ]] && echo spine || echo leaf)"
  done
}
shot P1-02 asn-loopback-plan host "tools: ASN and loopback per node, read from phases/p1-underlay/configs" asn_table

RT="show network-instance default route-table ipv4-unicast prefix 10.255.0.12/32"
shot P1-03 ecmp-route leaf1 "$RT   (compact)" srlt leaf1 "$RT" "Prefix,Route Type,Pref,Next-hop (Type),Next-hop Interface"
raw P1-03-route-full leaf1 "$RT"

# P1-04: 32 parallel TCP flows, then the per-uplink packet counters on leaf1.
ctr() { for i in 49 50; do echo -n "ethernet-1/$i out-packets: "; srl leaf1 "info from state interface ethernet-1/$i statistics out-packets" | awk '/out-packets/{print $2}'; done; }
hx client2 sh -c 'pkill iperf3; iperf3 -s -D' || true
before=$(ctr); hx client1 iperf3 -c 10.10.2.10 -P 32 -t 5 -M 1400 >/dev/null 2>&1 || true; after=$(ctr)
dist() {
  echo "method: iperf3 -P 32 -t 5 client1 -> client2, leaf1 uplink counters before/after"
  paste <(echo "$before") <(echo "$after") | awk '{b=$3; a=$6; printf "%-16s before=%-10s after=%-10s delta=%d\n", $1, b, a, a-b}'
}
shot P1-04 ecmp-flow-distribution leaf1 "iperf3 -c 10.10.2.10 -P 32; info from state interface ethernet-1/4{9,50} statistics" dist

# P1-05: the spine that carries the client1 -> client2 ping fails.
#   a) hard: its links go down (carrier loss, seen at once)
#   b) silent: links stay up, the spine drops everything (only BFD notices)
RTC="show network-instance default route-table ipv4-unicast prefix 10.10.2.0/24"
uplink_pkts() { srl leaf1 "info from state interface ethernet-1/$1 statistics out-packets" | awk '/out-packets/{print $2}'; }
active_spine() {
  local a1 a2 b1 b2; a1=$(uplink_pkts 49); a2=$(uplink_pkts 50)
  hx client1 ping -q -c 300 -i 0.005 10.10.2.10 >/dev/null 2>&1 || true
  b1=$(uplink_pkts 49); b2=$(uplink_pkts 50)
  if [ $((b1 - a1)) -ge $((b2 - a2)) ]; then echo spine1; else echo spine2; fi
}
ecmp2() { [ "$(srlt leaf1 "$RTC" "Prefix,Next-hop Interface" | grep -c ethernet-1/)" -ge 2 ]; }
wait_for 120 ecmp2
SP=$(active_spine)
spine_links() { docker run --rm --net "container:$(c "$SP")" --cap-add NET_ADMIN "$TOOLS_IMAGE" sh -c "ip link set e1-1 $1; ip link set e1-2 $1"; }
netem_loss() { for i in e1-1 e1-2; do "$REPO_ROOT/scripts/clab.sh" tools netem set -n "$(c "$SP")" -i $i --loss "$1" >/dev/null 2>&1; done; }
before_rt=$(srlt leaf1 "$RTC" "Prefix,Next-hop (Type),Next-hop Interface")
hard=$(outage client1 10.10.2.10 "$SP-links-down" spine_links down)
mid_rt=$(srlt leaf1 "$RTC" "Prefix,Next-hop (Type),Next-hop Interface")
spine_links up; wait_for 120 established leaf1 2; wait_for 120 established leaf2 2; wait_for 120 ecmp2; sleep 5
SP=$(active_spine)
silent=$(outage client1 10.10.2.10 "$SP-silent-drop" netem_loss 100)
netem_loss 0; wait_for 120 established leaf1 2; wait_for 120 established leaf2 2; sleep 5
failover() {
  echo "method: ping -i 0.01 client1 -> client2; the spine carrying it fails 3 s in;"
  echo "        loss time = lost pings x 10 ms. BFD 3 x 1 s (minimum of virtual SR Linux)."
  echo "$hard"; echo "$silent"
  echo; echo "leaf1 route to 10.10.2.0/24 before:"; echo "$before_rt"
  echo; echo "leaf1 route during the hard failure:"; echo "$mid_rt"
}
shot P1-05 spine-failure leaf1 - failover
rm -f "$OUT/failover.csv"
outage_csv failover.csv "ping -D -i 0.01 client1->client2; a) ip link down on both spine ports b) netem loss 100% on both spine ports" "$hard" "$silent"

# ---- BGP deep-dive shots (videos A6/A7). Test peers ext1-3 (FRR) and test
# prefixes only; every change below is reverted in the same block, so the
# underlay ends exactly as deployed.
cfg() { printf 'enter candidate\n%s\ncommit now\n' "$2" | docker exec -i "$(c "$1")" sr_cli >/dev/null; }
frr() { docker exec "$(c "$1")" vtysh "${@:2}" 2>/dev/null; }
NBC="Peer,Group,Peer-AS,State,Uptime,[Rx/Active/Tx]"
srl_events() { docker exec "$(c "$1")" grep "Peer $2 moved" /var/log/srlinux/buffer/messages | awk -v t="$T0" '$1 >= t' | tail -n "${3:-6}" \
  | sed -E 's/^([0-9T:.-]+)\.[0-9]+\+00:00 .*Peer [0-9.]+ (moved .*)/\1Z  \2/'; }
frr_events() { docker exec "$(c "$1")" sh -c "grep -E 'ADJCHANGE|NOTIFICATION|Bad Peer|state' /tmp/frr.log | tail -n ${2:-6}" | cut -c1-118; }
tp_up() { [ "$(srl leaf1 "$NB" | grep -cE '\| established ')" -ge 5 ]; }
wait_for 180 tp_up; sleep 15

T0=$(date -u +%Y-%m-%dT%H:%M:%S)   # events older than this test block are not shown
# P1-07 (a) all up
shot P1-07a sessions-all-up leaf1 "$NB   (compact)" srlt leaf1 "$NB" "$NBC"
# P1-07 (b) TCP 179 blocked on ext2, session bounced so it has to reconnect
docker run --rm --net "container:$(c ext2)" --cap-add NET_ADMIN "$TOOLS_IMAGE" sh -c 'iptables -A INPUT -p tcp --dport 179 -j DROP; iptables -A INPUT -p tcp --sport 179 -j DROP'
cfg leaf1 "set / network-instance default protocols bgp neighbor 10.253.2.1 admin-state disable"; sleep 2
cfg leaf1 "set / network-instance default protocols bgp neighbor 10.253.2.1 admin-state enable"; sleep 25
blocked() {
  echo "test: iptables on ext2 drops TCP 179; leaf1 bounces the session to 10.253.2.1"
  srlt leaf1 "$NB" "$NBC"; echo
  srl leaf1 "show network-instance default protocols bgp neighbor 10.253.2.1 detail" | grep -E 'session-state|Last-state|TCP connection' | head -3
  echo; echo "events (leaf1 log):"; srl_events leaf1 10.253.2.1 5
}
shot P1-07b session-tcp179-blocked leaf1 - blocked
docker run --rm --net "container:$(c ext2)" --cap-add NET_ADMIN "$TOOLS_IMAGE" sh -c 'iptables -F INPUT'
# P1-07 (c) ext3 expects the wrong AS from leaf1
frr ext3 -c 'conf t' -c 'router bgp 64503' -c 'neighbor 10.253.3.0 remote-as 65199' >/dev/null
frr ext3 -c 'clear bgp 10.253.3.0' >/dev/null; sleep 30
wrongas() {
  echo "test: ext3 configured with remote-as 65199 for leaf1 (leaf1 really is 65101)"
  srlt leaf1 "$NB" "$NBC" | grep -E 'Peer|---|10.253.3'; echo
  srl leaf1 "show network-instance default protocols bgp neighbor 10.253.3.1 detail" | grep -E 'session-state|Last-state|Notification' | head -3
  echo; echo "events (ext3, FRR log):"; frr_events ext3 6
  echo; echo "events (leaf1 log):"; srl_events leaf1 10.253.3.1 4
}
shot P1-07c session-wrong-as leaf1 - wrongas
frr ext3 -c 'conf t' -c 'router bgp 64503' -c 'no neighbor 10.253.3.0' -c 'neighbor 10.253.3.0 remote-as 65101' \
  -c 'neighbor 10.253.3.0 description leaf1' -c 'address-family ipv4 unicast' -c 'neighbor 10.253.3.0 route-map OUT out' >/dev/null
wait_for 180 tp_up
repaired() {
  echo "repair: iptables flushed on ext2, ext3 remote-as back to 65101"
  srlt leaf1 "$NB" "$NBC"
  echo; echo "events (leaf1 log):"; srl_events leaf1 10.253.2.1 2; srl_events leaf1 10.253.3.1 2
}
shot P1-07d sessions-repaired leaf1 - repaired

# P1-08 negotiated parameters: leaf1 holds 90 s, ext1 is configured with 180 s
neg() {
  echo "method: leaf1 default hold 90 s / keepalive 30 s; ext1 configured 'timers 60 180'"
  printf '%-8s %-22s %-22s\n' node "configured hold/ka" "negotiated hold/ka"
  l=$(srl leaf1 "show network-instance default protocols bgp neighbor 10.253.1.1 detail")
  lh=$(echo "$l" | awk '/^hold-time/{print $2"/"$3}'); lk=$(echo "$l" | awk '/^keepalive-interval/{print $2"/"$3}')
  printf '%-8s %-22s %-22s\n' leaf1 "${lh%/*} / ${lk%/*}" "${lh#*/} / ${lk#*/}"
  fr=$(frr ext1 -c "show bgp neighbors 10.253.1.0")
  fc=$(echo "$fr" | awk '/Configured hold time/{print $5" / "$10}'); fn=$(echo "$fr" | awk '/^  Hold time is/{print $4" / "$9}')
  printf '%-8s %-22s %-22s\n' ext1 "$fc" "$fn"
  echo; echo "ext1# show bgp neighbors 10.253.1.0   (excerpt)"
  echo "$fr" | grep -E 'BGP state|Hold time|4 Byte AS|Address Family IPv4|Route refresh:|Opens:|Notifications:|Updates:|Keepalives:|Sent +Rcvd' | head -12
  echo; echo "leaf1 capabilities:"; echo "$l" | grep -E '^Cap (Sent|Recv)'
}
shot P1-08 negotiated-timers-caps leaf1 - neg

# P1-09 best path among three candidates for 203.0.113.0/24
BP="show network-instance default protocols bgp routes ipv4 prefix 203.0.113.0/24 detail"
bp() { srl leaf1 "$BP" | grep -E 'Path [0-9]|Route source|LocalPref|Path  +:|Tie Break' | sed -E 's/Route Preference: MED is -, //'; }
wait_for 60 sh -c "docker exec $(c leaf1) sr_cli -d '$BP' | grep -q 'Received Paths: 3'"
bp_before=$(bp)
cfg leaf1 "set / routing-policy policy from-ext3 statement 10 action bgp local-preference set 50"; sleep 4
bp_after=$(bp)
cfg leaf1 "set / routing-policy policy from-ext3 statement 10 action bgp local-preference set 200"
best1() { echo "A=ext1 LP 100 [1 AS], B=ext2 LP 200 [3 AS], C=ext3 LP 200 [2 AS] (LP set by leaf1 import policy)"; echo "$bp_before"; }
shot P1-09a best-path-three-candidates leaf1 "$BP   (filtered)" best1
best2() { echo "change: leaf1 lowers LOCAL_PREF of ext3 (C) to 50 -> B wins on LOCAL_PREF over A"; echo "$bp_after"; }
shot P1-09b best-path-after-change leaf1 "$BP   (filtered)" best2

# P1-10 address families of an underlay session (IPv4 unicast only here)
AF="show network-instance default protocols bgp neighbor 10.254.1.0 detail"
afi() { srl leaf1 "$AF" | grep -E 'Peer :|session-state|^Cap |AFI/SAFI|End of RIB|Received routes|Active routes|Advertised routes|Rejected routes' | head -14
  echo; echo "the underlay carries IPv4 unicast only; the EVPN family follows in phase 2 (P2-02, P2-12)"; }
shot P1-10 session-address-families leaf1 "$AF   (filtered)" afi

# P1-11 communities on 198.51.100.0/24 (leaf1 tags 64500:100 and large 64500:1:100)
CP="show network-instance default protocols bgp routes ipv4 prefix 198.51.100.0/24 detail"
cline() { srl "$1" "$CP" | grep -E 'Path [0-9]|LocalPref|Path  +:|Communities' | sed -E 's/Route Preference: MED is -, //' | head -8; }
c_spine=$(cline spine1); c_leaf2=$(cline leaf2)
cfg leaf2 "set / routing-policy community-set tag-100 member [ 64500:100 ]
set / routing-policy policy underlay statement 30 match bgp community-set tag-100
set / routing-policy policy underlay statement 30 action bgp local-preference set 150"; sleep 5
c_rule=$(cline leaf2)
cfg leaf2 "delete / routing-policy policy underlay statement 30 match bgp community-set
delete / routing-policy policy underlay statement 30 action bgp local-preference
delete / routing-policy community-set tag-100"
cfg leaf1 "set / routing-policy community-set test-tags member [ 64500:100 64500:1:100 no-export ]"; sleep 6
c_ne_spine=$(cline spine1); c_ne_leaf2=$(srl leaf2 "$CP" | grep -cE 'Path [0-9]' || true)
cfg leaf1 "set / routing-policy community-set test-tags member [ 64500:100 64500:1:100 ]"
comm1() {
  echo "leaf1 exports 198.51.100.0/24 with 64500:100 + large 64500:1:100 (policy underlay-out)"
  echo "SR Linux sends standard and large communities to eBGP peers by default."
  echo; echo "spine1:"; echo "$c_spine"; echo; echo "leaf2:"; echo "$c_leaf2"
}
shot P1-11a communities-on-route spine1 "$CP   (filtered)" comm1
comm2() {
  echo "rule on leaf2: import statement for 198.51.100.0/24 matches community 64500:100"
  echo "and sets LOCAL_PREF 150 (reverted afterwards)"
  echo; echo "leaf2 before:"; echo "$c_leaf2" | grep -E 'Path [0-9]|LocalPref'
  echo; echo "leaf2 with the rule:"; echo "$c_rule" | grep -E 'Path [0-9]|LocalPref'
  echo; echo "NO_EXPORT variant: leaf1 adds no-export to the route"
  echo "spine1 (receives it, AS 65000):"; echo "$c_ne_spine" | grep -E 'Path [0-9]|Communities'
  echo "leaf2 (behind spine1, other AS): $c_ne_leaf2 paths received -> spine1 did not pass it on"
}
shot P1-11b community-policy-no-export leaf2 - comm2

matrix() { ping_matrix tmp-matrix.txt "client1 client2" "client1=10.10.1.10 client2=10.10.2.10 leaf1=10.255.0.11 leaf2=10.255.0.12 spine1=10.255.0.1 spine2=10.255.0.2" "-I eth1"; cat "$OUT/tmp-matrix.txt"; rm -f "$OUT/tmp-matrix.txt"; echo; hx client1 traceroute -I -N 1 -n -w1 -q1 10.10.2.10; }
shot P1-12 ping-matrix-traceroute client1 "ping matrix (3 pings each) + traceroute -I 10.10.2.10" matrix

mem_table > "$OUT/memory.txt"
graph_export "$HERE/topology.clab.yml"
render_pngs
ls "$OUT"
