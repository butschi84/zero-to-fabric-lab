#!/usr/bin/env bash
# Phase 9 fault scenarios, each: before -> inject -> wait until the MONITORING
# shows it (Prometheus, fed by gnmic -> site collector) -> during -> repair -> after.
# Detection time = from the injection to the first Prometheus answer that shows
# the fault (includes the 5 s gNMI sample interval and the collector's export batch).
#   bash faults.sh link | mac | mtu | sitecut | onchange | wan | all
# Optional: SHOT_CMD="<cmd>" is called as `<cmd> <fault> <before|during|after>`
# (used to take dashboard screenshots; not part of the lab).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB=ztf-p9 OUT="$HERE/../../evidence/p9-observability"
source "$HERE/../../scripts/lib.sh"
PROM=http://127.0.0.1:19090
pq() { curl -s "$PROM/api/v1/query" --data-urlencode "query=$1" | python3 -c 'import json,sys
r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "nan")'; }
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
shot() { [ -n "${SHOT_CMD:-}" ] && $SHOT_CMD "$1" "$2" || true; }
# optional screen recording of the dashboard around the injection (CAST_CMD <fault>, runs in the background)
cast() { if [ -n "${CAST_CMD:-}" ]; then ($CAST_CMD "$1" >/dev/null 2>&1 &); sleep 5; fi; }
cfg() { printf 'enter candidate\n%s\ncommit now\n' "$2" | docker exec -i "$(c "$1")" sr_cli >/dev/null; }
# wait until a PromQL expression returns a value matching an awk condition; prints seconds since $T0
detect() { local q="$1" cond="$2" max="${3:-120}" v
  for _ in $(seq 1 "$max"); do v=$(pq "$q"); if awk -v v="$v" "BEGIN{exit !($cond)}"; then echo "$(( $(date +%s) - T0 ))"; return 0; fi; sleep 1; done; echo "not detected in ${max}s"; }
# a Grafana annotation (tag "fault") on both dashboards, so the picture shows when what happened
annotate() { curl -s -u admin:ZeroToFabric-lab1 -H 'Content-Type: application/json' -X POST http://127.0.0.1:13000/api/annotations \
  -d "{\"time\": $(( $(date +%s) * 1000 )), \"tags\": [\"fault\"], \"text\": \"$1\"}" >/dev/null || true; }
csv() { [ -f "$OUT/detection.csv" ] || echo "fault,injected_utc,signal,detection_s,method" > "$OUT/detection.csv"; echo "$1" >> "$OUT/detection.csv"; }
# fault traffic uses port 5301, so it never touches the background load of load.sh (ports 54xx)
traffic_start() { # TCP from site A (a-c2, corp 02) to site B (b-c3, corp 03): L3 between the sites over DCI
  hx b-c3 iperf3 -s -D -p 5301 >/dev/null 2>&1 || true   # a second start just fails to bind; pgrep -f would match its own sh -c
  docker exec -d "$(c a-c2)" sh -c "iperf3 -c 10.1.3.21 -p 5301 -P 8 -t ${1:-120} -b 2M > /tmp/iperf-$2.txt 2>&1"; }
traffic_stop() { docker exec "$(c a-c2)" sh -c "pkill -f '[i]perf3 -c 10.1.3.21 -p 5301'; true"; }

BGP=srl_network_instance_protocols_bgp_neighbor_session_state
BFD=srl_bfd_network_instance_peer_session_state
E7='rate(srl_interface_statistics_out_octets_total{source="spine-a",interface_name="ethernet-1/7"}[15s])*8'
E8='rate(srl_interface_statistics_out_octets_total{source="spine-a",interface_name="ethernet-1/8"}[15s])*8'

link() { # spine-a <-> gw-a link fails (interface down in spine-a's namespace)
  traffic_start 150 link; sleep 25
  local b_bgp b_bfd b7 b8; b_bgp=$(pq "sum($BGP{source=\"spine-a\"})"); b_bfd=$(pq "sum($BFD{source=\"spine-a\"})"); b7=$(pq "$E7"); b8=$(pq "$E8")
  shot link before
  cast link
  local t0; t0=$(ts); T0=$(date +%s)
  docker run --rm --net "container:$(c spine-a)" --cap-add NET_ADMIN "$TOOLS_IMAGE" ip link set e1-7 down; annotate "Link down spine-a e1-7 - gw-a"
  local d_bgp d_ecmp; d_bgp=$(detect "sum($BGP{source=\"spine-a\"})" "v < $b_bgp"); d_ecmp=$(detect "$E7" "v < 1000")
  sleep 12; local m_bgp m_bfd m7 m8; m_bgp=$(pq "sum($BGP{source=\"spine-a\"})"); m_bfd=$(pq "sum($BFD{source=\"spine-a\"})"); m7=$(pq "$E7"); m8=$(pq "$E8")
  shot link during
  docker run --rm --net "container:$(c spine-a)" --cap-add NET_ADMIN "$TOOLS_IMAGE" ip link set e1-7 up; annotate "Link up spine-a e1-7 - gw-a"
  T0=$(date +%s); local r_bgp; r_bgp=$(detect "sum($BGP{source=\"spine-a\"})" "v >= $b_bgp" 180)
  sleep 20; local a_bgp a7 a8; a_bgp=$(pq "sum($BGP{source=\"spine-a\"})"); a7=$(pq "$E7"); a8=$(pq "$E8")
  shot link after; traffic_stop
  csv "link,$t0,BGP sessions on spine-a drop,$d_bgp,ip link set e1-7 down in spine-a; gNMI sample 5 s"
  csv "link,$t0,ECMP: spine-a e1-7 traffic < 1 kbit/s,$d_ecmp,rate over 15 s"
  csv "link-repair,$t0,BGP sessions on spine-a back,$r_bgp,ip link set e1-7 up"
  { echo "method: spine-a e1-7 (to gw-a) down / up; 8 TCP flows a-c2 -> b-c3 at 2 Mbit/s each over the DCI"
    echo "detection = injection -> first Prometheus answer showing it (gnmic sample 5 s + collector export)"; echo
    printf '%-38s %-12s %-12s %-12s\n' metric before during after
    printf '%-38s %-12s %-12s %-12s\n' "BGP sessions established (spine-a)" "$b_bgp" "$m_bgp" "$a_bgp"
    printf '%-38s %-12s %-12s %-12s\n' "BFD sessions up (spine-a)" "$b_bfd" "$m_bfd" "$(pq "sum($BFD{source=\"spine-a\"})")"
    printf '%-38s %-12.0f %-12.0f %-12.0f\n' "spine-a e1-7 -> gw-a  out bit/s" "$b7" "$m7" "$a7"
    printf '%-38s %-12.0f %-12.0f %-12.0f\n' "spine-a e1-8 -> gw-a2 out bit/s" "$b8" "$m8" "$a8"
    echo; echo "detected: BGP drop after ${d_bgp} s, ECMP shift after ${d_ecmp} s; recovery seen after ${r_bgp} s"
  } > "$OUT/P9-fault-link.txt"
}

mac() { # the same MAC in both sites on the stretched VLAN 101: b-c1 takes a-c1's MAC
  local MAC=02:00:00:0a:01:11 ORIG; ORIG=$(hx b-c1 cat /sys/class/net/eth1/address)
  local Q='sum(srl_network_instance_bridge_table_statistics_mac_type_active_entries{mac_type_type="duplicate"}) or vector(0)'
  local b; b=$(pq "$Q"); shot mac before
  cast mac
  local t0; t0=$(ts); T0=$(date +%s)
  hx b-c1 sh -c "ip link set eth1 address $MAC"; annotate "Duplicate MAC $MAC in site A and site B"
  # both hosts talk with the same source MAC: the fabric sees it move back and forth
  for _ in $(seq 1 40); do hx a-c1 arping -c1 -U -I eth1 10.1.1.11 >/dev/null 2>&1 || true; hx b-c1 arping -c1 -U -I eth1 10.1.1.21 >/dev/null 2>&1 || true; sleep 0.5; done &
  local d; d=$(detect "$Q" "v > 0" 180); wait
  sleep 6; local m; m=$(pq "$Q")
  local dup; dup=$(for n in leaf-a1 leaf-b1; do srlt "$n" "show network-instance mac-vrf-101 bridge-table mac-table all" "Address,Destination,Type" | grep -iE "Address|0A:01:11" | sed "s/^/$n  /"; done)
  local logs; logs=$(for n in leaf-a1 leaf-b1; do docker exec "$(c "$n")" grep "sr_l2_mac_mgr" /var/log/srlinux/buffer/messages | grep -i duplicate | tail -2 | sed -E 's/^([0-9T:-]+)\.[0-9]+\+00:00 /\1Z /' | cut -c1-150; done)
  shot mac during
  hx b-c1 sh -c "ip link set eth1 address $ORIG"; annotate "MAC fixed, duplicate released"
  # a duplicate MAC stays blocked for the hold-down time; the operator releases it explicitly
  for n in leaf-a1 leaf-b1; do docker exec "$(c "$n")" sr_cli -d "tools network-instance mac-vrf-101 bridge-table mac-duplication duplicate-entries mac $MAC delete-mac" >/dev/null 2>&1 || true; done
  T0=$(date +%s); local r; r=$(detect "$Q" "v == 0" 180); sleep 6; local a; a=$(pq "$Q"); shot mac after
  csv "mac,$t0,duplicate MAC entries > 0,$d,b-c1 set to a-c1's MAC; both send GARP every 0.5 s"
  { echo "method: b-c1 (site B) takes a-c1's MAC $MAC on the stretched VLAN 101; both send gratuitous ARP"
    echo "every 0.5 s; SR Linux MAC duplication detection (default: 5 moves in 3 min) marks it duplicate"; echo
    printf '%-34s %-8s %-8s %-8s\n' metric before during after
    printf '%-34s %-8s %-8s %-8s\n' "duplicate MAC entries (fabric)" "$b" "$m" "$a"
    echo; echo "detected after ${d} s; cleared (MAC restored + delete-mac on both leafs) after ${r} s"
    echo; echo "MAC table entries for $MAC during the fault (type duplicate = blocked):"; echo "$dup"
    echo; echo "leaf logs (also delivered as syslog via the site collectors to Loki):"; echo "$logs"
  } > "$OUT/P9-fault-mac.txt"
}

mtu() { # WAN IP MTU drops from 9000 to 1500 on all four gateways: full-size VXLAN packets no longer fit
  local DQ='sum(rate(srl_interface_statistics_out_discarded_packets_total{source=~"gw-.*",interface_name="ethernet-1/1"}[15s])) + sum(rate(srl_interface_statistics_in_discarded_packets_total{source=~"gw-.*"}[15s]))'
  local TQ='sum(rate(srl_interface_statistics_out_octets_total{source=~"gw-a|gw-a2",interface_name="ethernet-1/1"}[15s]))*8'
  ipf() { hx b-c3 iperf3 -s -D -p 5301 >/dev/null 2>&1 || true   # a second start just fails to bind; pgrep -f would match its own sh -c
    hx a-c2 sh -c "iperf3 -c 10.1.3.21 -p 5301 -t 8 $1 2>&1 | grep -E 'sender|receiver|error' | head -2"; }
  local pre_def; pre_def=$(ipf "")
  traffic_start 150 mtu; sleep 30; local b_d b_t; b_d=$(pq "$DQ"); b_t=$(pq "$TQ"); shot mtu before
  cast mtu
  local t0; t0=$(ts); T0=$(date +%s)
  for g in gw-a gw-a2 gw-b gw-b2; do cfg "$g" "set / interface ethernet-1/1 subinterface 0 ip-mtu 1500"; done; annotate "WAN MTU 9000 -> 1500 on the gateways"
  local d; d=$(detect "$TQ" "v < $b_t - 12000000" 90); sleep 12; local m_d m_t; m_d=$(pq "$DQ"); m_t=$(pq "$TQ"); shot mtu during
  traffic_stop; sleep 2
  local dur_def dur_mss; dur_def=$(ipf ""); dur_mss=$(ipf "-M 1356")
  for g in gw-a gw-a2 gw-b gw-b2; do cfg "$g" "set / interface ethernet-1/1 subinterface 0 ip-mtu 9000"; done; annotate "WAN MTU back to 9000"
  traffic_start 60 mtu-after; sleep 30; local a_d a_t; a_d=$(pq "$DQ"); a_t=$(pq "$TQ"); shot mtu after; traffic_stop
  csv "mtu,$t0,DCI throughput falls by > 12 Mbit/s (the 8 TCP flows),$d,WAN ip-mtu 9000 -> 1500 on the four gateways during 8 running TCP flows"
  { echo "method: WAN ip-mtu 9000 -> 1500 on gw-a/gw-a2/gw-b/gw-b2 while 8 TCP flows a-c2 -> b-c3 run (default MSS 1448)."
    echo "A 1500-byte host packet + 50 bytes VXLAN no longer fits; the hosts are not told (no ICMP reaches them)."; echo
    printf '%-40s %-12s %-12s %-12s\n' metric before during after
    printf '%-40s %-12.0f %-12.0f %-12.0f\n' "gw-a/gw-a2 WAN out bit/s" "$b_t" "$m_t" "$a_t"
    printf '%-40s %-12.2f %-12.2f %-12.2f\n' "gateway discards per second (gNMI)" "$b_d" "$m_d" "$a_d"
    echo; echo "detected (throughput collapse in Prometheus) after ${d} s."
    echo "The dropped packets do NOT show up as interface discards in SR Linux's counters here."
    echo; echo "iperf3 8 s, default MSS, before:"; echo "$pre_def"
    echo "iperf3 8 s, default MSS, during:"; echo "${dur_def:-<no data>}"
    echo "iperf3 8 s, MSS 1356 (-M), during:"; echo "$dur_mss"
  } > "$OUT/P9-fault-mtu.txt"
}

sitecut() { # site B's collector loses its path to the NOC (LinkMesh, Prometheus, Loki) for 120 s
  local Q='count(srl_interface_oper_state{site="b"})'
  cast sitecut
  local t0; t0=$(ts); T0=$(date +%s); local cut_start; cut_start=$(date +%s)
  docker run --rm --net container:ztf-p9-collector-b --cap-add NET_ADMIN "$TOOLS_IMAGE" sh -c \
    'for ip in 172.30.30.200 172.30.30.210 172.30.30.212; do iptables -A OUTPUT -d $ip -j DROP; iptables -A INPUT -s $ip -j DROP; done'
  annotate "Site B collector cut off from the NOC"
  local AGE='time() - max(timestamp(srl_interface_oper_state{site="b"}))'   # age of site B's newest sample
  local d; d=$(detect "$AGE" "v > 15" 90)
  local q_during; q_during=$(docker exec ztf-p9-collector-b du -sh /var/lib/otelcol-supervisor/sending-queue 2>/dev/null | cut -f1)
  shot sitecut during
  sleep 100; local cut_end; cut_end=$(date +%s)
  local lm_state; lm_state=$("$HERE/obs/linkmesh/lm-collectors.sh" 2>/dev/null || true)
  local q_peak; q_peak=$(docker exec ztf-p9-collector-b du -sh /var/lib/otelcol-supervisor/sending-queue 2>/dev/null | cut -f1)
  docker run --rm --net container:ztf-p9-collector-b --cap-add NET_ADMIN "$TOOLS_IMAGE" sh -c 'iptables -F OUTPUT; iptables -F INPUT'; annotate "Site B collector reconnected"
  T0=$(date +%s); local r; r=$(detect "$AGE" "v < 10" 120)
  sleep 60
  # samples Prometheus holds for site B inside the cut window, counted AFTER the backlog was delivered
  local win=$((cut_end - cut_start - 10))
  local held; held=$(pq "count_over_time(srl_interface_oper_state{site=\"b\",source=\"leaf-b1\",interface_name=\"ethernet-1/49\"}[${win}s] offset $(( $(date +%s) - cut_end + 5 ))s)")
  local expect=$(( win / 5 ))
  shot sitecut after
  csv "sitecut,$t0,site B newest sample older than 15 s,$d,iptables DROP to/from LinkMesh/Prometheus/Loki in collector-b's namespace"
  { echo "method: collector-b (site B) cut off from the NOC for $((cut_end - cut_start)) s (iptables in its namespace);"
    echo "        gnmic-b, syslog and the SR Linux nodes of site B keep running"; echo
    echo "site B's newest sample in Prometheus older than 15 s after ${d} s; fresh again (< 10 s) ${r} s after the repair"
    echo "collector-b durable queue on disk: ${q_during:-?} shortly after the cut, ${q_peak:-?} at the end of the cut"
    echo "samples in Prometheus for leaf-b1 e1-49 oper-state INSIDE the cut window, counted after the repair:"
    echo "  ${held} of ~${expect} expected (5 s sampling) -> the collector buffered and delivered them late"
    echo; echo "LinkMesh view of the collectors during the cut:"; echo "${lm_state:-<not captured>}"
  } > "$OUT/P9-fault-sitecut.txt"
}

onchange() { # how fast does the monitoring learn about a link failure: gNMI ON_CHANGE vs SAMPLE 30 s
  local G="docker run --rm --network ztf-mgmt ghcr.io/openconfig/gnmic:0.50.0 -a 172.30.30.11:57400 -u admin -p NokiaSrl1! --skip-verify -e json_ietf"
  local P='/interface[name=ethernet-1/7]/oper-state'
  docker rm -f ztf-p9-sub-oc ztf-p9-sub-s30 >/dev/null 2>&1 || true
  docker run -d --name ztf-p9-sub-oc --network ztf-mgmt ghcr.io/openconfig/gnmic:0.50.0 -a 172.30.30.11:57400 -u admin -p 'NokiaSrl1!' --skip-verify -e json_ietf \
    subscribe --path "$P" --stream-mode on-change --format event >/dev/null
  docker run -d --name ztf-p9-sub-s30 --network ztf-mgmt ghcr.io/openconfig/gnmic:0.50.0 -a 172.30.30.11:57400 -u admin -p 'NokiaSrl1!' --skip-verify -e json_ietf \
    subscribe --path "$P" --stream-mode sample --sample-interval 30s --format event >/dev/null
  sleep 35
  local t0ms; t0ms=$(python3 -c 'import time;print(int(time.time()*1000))'); T0=$(date +%s); local t0; t0=$(ts)
  docker run --rm --net "container:$(c spine-a)" --cap-add NET_ADMIN "$TOOLS_IMAGE" ip link set e1-7 down; annotate "Link down spine-a e1-7 (gNMI on-change vs sample 30 s)"
  sleep 40
  docker run --rm --net "container:$(c spine-a)" --cap-add NET_ADMIN "$TOOLS_IMAGE" ip link set e1-7 up; annotate "Link up spine-a e1-7"
  first_down() { docker logs "$1" 2>/dev/null | python3 -c '
import json,sys
t0=int(sys.argv[1]); txt=sys.stdin.read(); dec=json.JSONDecoder(); i=0; best=None
while i < len(txt):
    j=txt.find("[", i)
    if j<0: break
    try: ev,i=dec.raw_decode(txt, j)
    except ValueError: i=j+1; continue
    for e in ev if isinstance(ev,list) else [ev]:
        v=str(list(e.get("values",{}).values())[0]) if e.get("values") else ""
        ts=e.get("timestamp",0)//1000000
        if v=="down" and ts>=t0-1000 and (best is None or ts<best): best=ts
print("%.1f" % ((best-t0)/1000) if best else "none")' "$t0ms"; }
  local oc s30; oc=$(first_down ztf-p9-sub-oc); s30=$(first_down ztf-p9-sub-s30)
  docker rm -f ztf-p9-sub-oc ztf-p9-sub-s30 >/dev/null 2>&1 || true
  csv "onchange,$t0,first 'down' notification via gNMI ON_CHANGE,$oc,gnmic subscribe on spine-a e1-7 oper-state"
  csv "onchange,$t0,first 'down' notification via gNMI SAMPLE 30 s,$s30,gnmic subscribe on spine-a e1-7 oper-state"
  { echo "method: spine-a e1-7 down; two gnmic subscriptions to /interface[name=ethernet-1/7]/oper-state run side by side;"
    echo "        seconds from the injection to the device timestamp of the first update saying 'down'"; echo
    printf '%-28s %s\n' "subscription" "first 'down' after (s)"
    printf '%-28s %s\n' "ON_CHANGE" "$oc"; printf '%-28s %s\n' "SAMPLE, interval 30 s" "$s30"
    echo; echo "the lab's dashboards use SAMPLE 5 s (obs/gnmic): worst case ~5 s plus the collector's export batch"
  } > "$OUT/P9-onchange-vs-sample.txt"
}

wanlatency() { # latency and jitter between the sites before / with / after WAN impairment (netem on site B's WAN ports)
  local RTT='avg(rate(smokeping_response_duration_seconds_sum{instance="172.30.30.101:9374",host=~"10.1.1.21|10.1.3.21"}[1m]) / rate(smokeping_response_duration_seconds_count{instance="172.30.30.101:9374",host=~"10.1.1.21|10.1.3.21"}[1m])) * 1000'
  local JIT='(histogram_quantile(0.9, sum by (le) (rate(smokeping_response_duration_seconds_bucket{instance="172.30.30.101:9374",host=~"10.1.1.21|10.1.3.21"}[1m]))) - histogram_quantile(0.1, sum by (le) (rate(smokeping_response_duration_seconds_bucket{instance="172.30.30.101:9374",host=~"10.1.1.21|10.1.3.21"}[1m])))) * 1000'
  local b_r b_j; b_r=$(pq "$RTT"); b_j=$(pq "$JIT"); shot wan before
  local t0; t0=$(ts)
  for g in gw-b gw-b2; do "$REPO_ROOT/scripts/clab.sh" tools netem set -n "$(c "$g")" -i e1-1 --delay 30ms --jitter 5ms >/dev/null 2>&1; done
  annotate "WAN impaired: 30 ms delay, 5 ms jitter on site B's WAN ports"
  sleep 75; local m_r m_j; m_r=$(pq "$RTT"); m_j=$(pq "$JIT"); shot wan during
  for g in gw-b gw-b2; do "$REPO_ROOT/scripts/clab.sh" tools netem set -n "$(c "$g")" -i e1-1 --delay 0ms --jitter 0ms >/dev/null 2>&1; done
  annotate "WAN impairment removed"
  sleep 75; local a_r a_j; a_r=$(pq "$RTT"); a_j=$(pq "$JIT"); shot wan after
  { echo "method: containerlab tools netem on gw-b and gw-b2 e1-1 (site B's WAN ports): delay 30 ms, jitter 5 ms, 75 s;"
    echo "        ICMP probes every 1 s from a-c1 (site A) to b-c1 and b-c3 (site B), 1-minute windows from Prometheus"; echo
    printf '%-30s %-10s %-10s %-10s\n' "metric (ms)" before during after
    printf '%-30s %-10.1f %-10.1f %-10.1f\n' "RTT A -> B (avg)" "$b_r" "$m_r" "$a_r"
    printf '%-30s %-10.1f %-10.1f %-10.1f\n' "jitter (p90 - p10 RTT)" "$b_j" "$m_j" "$a_j"
    echo; echo "the delay hits one direction of the path (site B's egress), so the RTT rises by ~30 ms"
  } > "$OUT/P9-wan-latency-jitter.txt"
}

case "${1:-all}" in
  link) link;; mac) mac;; mtu) mtu;; sitecut) sitecut;; onchange) onchange;; wan) wanlatency;;
  # FAULT_GAP: seconds between the scenarios (default 30; 600-900 for a dashboard that shows each one apart)
  all) G=${FAULT_GAP:-30}; rm -f "$OUT/detection.csv"; link; sleep "$G"; mac; sleep "$G"; mtu; sleep "$G"; sitecut; sleep "$G"; wanlatency; sleep "$G"; onchange;;
  *) echo "usage: $0 link|mac|mtu|sitecut|onchange|wan|all" >&2; exit 2;;
esac
