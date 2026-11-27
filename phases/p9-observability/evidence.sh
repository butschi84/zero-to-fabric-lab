#!/usr/bin/env bash
# Phase 9 evidence (steady state). Run after `make deploy PHASE=p9-observability`
# (which also starts obs/up.sh). Fault scenarios: faults.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB=ztf-p9 OUT="$HERE/../../evidence/p9-observability"
source "$HERE/../../scripts/lib.sh"
PROM=http://127.0.0.1:19090
pqt() { curl -s "$PROM/api/v1/query" --data-urlencode "query=$1" | python3 -c 'import json,sys
for r in json.load(sys.stdin)["data"]["result"]:
    m=r["metric"]; print("  ".join(f"{k}={m[k]}" for k in sys.argv[1].split(",") if k in m), "=", round(float(r["value"][1]),2))' "$2"; }
gn() { docker run --rm --network ztf-mgmt ghcr.io/openconfig/gnmic:0.50.0 -a "$1:57400" -u admin -p 'NokiaSrl1!' --skip-verify -e json_ietf "${@:2}"; }

flow() {
  printf '%-14s %-15s %s\n' container address role
  for x in "linkmesh 172.30.30.200 LinkMesh server (collector fleet, config over OpAMP)" "collector-a 172.30.30.201 collector site A (+ branch)" \
           "collector-b 172.30.30.202 collector site B" "gnmic-a 172.30.30.203 gNMI subscriber site A -> OTLP -> collector-a" \
           "gnmic-b 172.30.30.204 gNMI subscriber site B -> OTLP -> collector-b" "prometheus 172.30.30.210 metrics (OTLP receiver)" \
           "grafana 172.30.30.211 dashboards" "loki 172.30.30.212 syslog (OTLP)"; do set -- $x; printf '%-14s %-15s %s\n' "$1" "$2" "${*:3}"; done
  echo; echo "SR Linux --gNMI (TLS 57400)--> gnmic --OTLP/gRPC--> site collector --OTLP/HTTP, durable queue--> Prometheus"
  echo "SR Linux --syslog UDP 5514 (RFC 5424)--> site collector --OTLP/HTTP, durable queue--> Loki"
  echo "probes (smokeping, in a-c1 / b-c1) + IPsec exporters <--scrape-- site collector"
  echo "all of it on the out-of-band management network 172.30.30.0/24 (SR Linux network-instance mgmt)"
}
shot P9-01 data-flow host - flow

paths() { grep -E '^      - /' "$HERE/obs/gnmic/gnmic-a.yaml" | sed 's/^      - //' | sed -n '1,26p'; }
shot P9-02 gnmi-paths host "grep paths obs/gnmic/gnmic-a.yaml   (subscribed by gnmic-a and gnmic-b)" paths
bgpget() { gn 172.30.30.21 get --path '/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]/session-state' --format flat 2>&1 | sed 's#srl_nokia-[a-z-]*:##g' | head -6
  echo; gn 172.30.30.21 get --path '/network-instance[name=*]/bridge-table/statistics/active-entries' --format flat 2>&1 | sed 's#srl_nokia-[a-z-]*:##g' | head -6; }
shot P9-03 gnmi-get-example host "gnmic -a leaf-a1:57400 get --path .../bgp/neighbor[*]/session-state ; .../bridge-table/statistics" bgpget

srlobs() { srl leaf-a1 "info flat system logging remote-server *"; srl leaf-a1 "info flat system sflow"; srl leaf-a1 "info flat system grpc-server mgmt" | head -6; }
shot P9-04 srl-obs-config leaf-a1 "info flat system logging remote-server * / system sflow / grpc-server mgmt" srlobs

# sFlow: SR Linux sends it, LinkMesh 1.501.1 cannot configure a receiver for it
pcap leaf-a1 any 15 P9-05-sflow.pcap "udp port 6343"; hx a-c1 ping -q -i 0.002 -c 3000 10.1.1.21 >/dev/null 2>&1 || true; pcap_wait
sfl() { echo "3000 pings a-c1 -> b-c1 across leaf-a1 during a 15 s capture, sampling 1:1000 on every fabric port"
  docker run --rm -v "$OUT:/out" "$TOOLS_IMAGE" sh -c 'echo "datagrams: $(tshark -r /out/P9-05-sflow.pcap 2>/dev/null | wc -l)"; tshark -r /out/P9-05-sflow.pcap -V 2>/dev/null | grep -oE "(Counters|Flow|Expanded counters|Expanded flow) sample \(" | sort | uniq -c | sed "s/ (//"'
  docker run --rm -v "$OUT:/out" "$TOOLS_IMAGE" sh -c 'tshark -r /out/P9-05-sflow.pcap -V 2>/dev/null | awk "/^Frame/{n++} n==1"' | grep -E "Datagram version|Agent address:|Interface index|Interface Speed|Input Octets|Output Octets" | head -6
  echo; echo "-> virtual SR Linux sends sFlow v5 COUNTER samples only, no flow samples (no packet sampling in its datapath)."
  echo; echo "LinkMesh 1.501.1, POST /api/v1/sources receiverType netflow (the collector's sFlow receiver):"
  python3 -c 'import json,sys;d=json.loads(open(sys.argv[1]).read().split(" ",1)[1]);print(" ", d["code"], "-", d["error"][:200])' "$OUT/linkmesh-netflow-refusal.txt"; }
shot P9-05 sflow-sent-not-collected leaf-a1 "tshark -r P9-05-sflow.pcap (sample types; first datagram excerpt)" sfl

lm() { "$HERE/obs/linkmesh/lm-collectors.sh"; echo
  python3 - "$OUT/linkmesh" <<'PY'
import json,sys,pathlib
d=pathlib.Path(sys.argv[1])
own=lambda f: [x for x in json.loads((d/f).read_text()) if not x.get("isTemplate") and not x.get("builtIn") and x.get("name","").split(" ")[0] in ("gNMI","SR","Probes","Prometheus","Loki")]
for x in own("sources.json"): print(f"source       {x['name']:<46} {x['receiverType']:<10} {json.dumps(x.get('defaultConfig'))[:60]}")
for x in own("destinations.json"): print(f"destination  {x['name']:<46} {x['exporterType']:<10} {x['defaultConfig'].get('endpoint')} durable_queue={x['defaultConfig'].get('durable_queue')}")
for f in sorted(d.glob("routes-site-*.json")):
    for r in json.loads(f.read_text()):
        if r["priority"] < 1000000: print(f"route        {r['name']:<46} filter={r['inputFilter']} destinations={len(r.get('destinationIds') or [])}")
PY
}
shot P9-06 linkmesh-fleet-and-config host "LinkMesh API: collectors, sources, destinations, routes (written by obs/linkmesh/bootstrap.py)" lm

eff() { docker exec ztf-p9-collector-a cat /var/lib/otelcol-supervisor/effective.yaml > "$OUT/linkmesh/effective-config-collector-a.yaml"
  docker exec ztf-p9-collector-b cat /var/lib/otelcol-supervisor/effective.yaml > "$OUT/linkmesh/effective-config-collector-b.yaml"
  sed -i.bak -E 's/Bearer [0-9a-f]{20,}/Bearer <redacted>/g' "$OUT"/linkmesh/effective-config-collector-*.yaml && rm -f "$OUT"/linkmesh/*.bak   # enrollment token
  python3 -c 'import yaml,sys;d=yaml.safe_load(open(sys.argv[1]))
print("receivers:", ", ".join(d["receivers"]))
for k,v in d["exporters"].items():
    q=v.get("sending_queue",{}); print("exporter", k, v.get("endpoint"), "queue storage:", q.get("storage","-"), "queue size:", q.get("queue_size","-"))
print("pipelines:", len(d["service"]["pipelines"]), "  extensions:", ", ".join(d["service"].get("extensions",[])))' "$OUT/linkmesh/effective-config-collector-a.yaml"; }
shot P9-07 collector-effective-config collector-a "cat /var/lib/otelcol-supervisor/effective.yaml   (summary; full file in linkmesh/)" eff

R='srl_network_instance_bgp_rib_afi_safi_evpn_rib_in_out_rib_in_post'
prom() { echo "EVPN routes in use per type (leaf-a1, leaf-b1):"
  for t in mac_ip:Type-2 imet:Type-3 ip_prefix:Type-5; do pqt "sum by (source) (${R}_${t%%:*}_route_used_route{source=~\"leaf-.*\"})" source | sed "s/^/  ${t##*:} /"; done
  echo "remote VTEPs per leaf:"; pqt 'count by (source) (srl_tunnel_vxlan_tunnel_vtep_index{source=~"leaf-.*"})' source | sed 's/^/  /'
  echo "MAC table size (active entries) per MAC-VRF on the leafs:"; pqt 'srl_network_instance_bridge_table_statistics_active_entries{source=~"leaf-.*"}' source,network_instance_name | sed 's/^/  /'
  echo "IPv4 routes per tenant VRF (leaf-a1):"; pqt 'srl_network_instance_route_table_ipv4_unicast_statistics_active_routes{source="leaf-a1",network_instance_name!~"default|mgmt"}' network_instance_name | sed 's/^/  /'; }
shot P9-08 overlay-tenants-in-prometheus host "PromQL against the metrics gnmic -> collector -> Prometheus delivered" prom

wan() { echo "probe RTT avg over 1 min (smokeping in a-c1 / b-c1; ICMP across leafs, DCI and IPsec):"
  pqt 'rate(smokeping_response_duration_seconds_sum[1m]) / rate(smokeping_response_duration_seconds_count[1m]) * 1000' instance,host | sed 's/172.30.30.101:9374/a-c1/; s/172.30.30.103:9374/b-c1/; s/^/  /; s/= /= ms /'
  echo "IPsec (strongSwan exporter in the IPsec containers):"; pqt 'ipsec_ike_sa_established' gateway,tunnel,peer | sed 's/^/  IKE SA up /'
  pqt 'rate(ipsec_child_sa_bytes_total[1m]) * 8' gateway,tunnel,direction | sed 's/^/  ESP bit\/s /'; }
shot P9-09 sites-latency-ipsec host "PromQL: probe latency between the sites, IPsec SAs" wan

logs() { docker run --rm --network ztf-mgmt "$TOOLS_IMAGE" sh -c 'curl -s -G http://172.30.30.212:3100/loki/api/v1/query_range --data-urlencode "query={service_name=\"unknown_service\"} != \"TLS profile\"" --data-urlencode limit=12' \
  | python3 -c 'import json,sys;v=[x for s in json.load(sys.stdin)["data"]["result"] for x in s["values"]];v.sort();[print(l[1][:140]) for l in v[-12:]]'; }
shot P9-10 syslog-in-loki host "Loki: {service_name=\"unknown_service\"} != \"TLS profile\"   (last 12 lines)" logs

mem() {
  echo "method: memory.current of each container cgroup; docker stats for the observability containers"
  local tot=0 m; for cn in $(docker ps --format '{{.Names}}' | grep "^clab-${LAB}-" | grep -v -- '-netns$' | sort); do m=$(docker exec "$cn" cat /sys/fs/cgroup/memory.current 2>/dev/null || echo 0); tot=$((tot + m / 1048576)); done
  echo "lab nodes (9 SR Linux + Linux/FRR/strongSwan): $tot MiB"
  local o=0; while read -r n v u; do printf '  %-22s %8s\n' "$n" "$v$u"; o=$(python3 -c "print(round($o + $v * (1024 if '$u'=='GiB' else 1 if '$u'=='MiB' else 1/1024)))"); done < <(docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' | grep '^ztf-p9-' | awk '{print $1, $2}' | sed -E 's/([0-9.]+)([A-Za-z]+)$/\1 \2/')
  echo "observability stack: $o MiB"
  docker run --rm --privileged --pid host alpine:3.22 free -m | sed -n 1,2p
}
mem > "$OUT/memory.txt"
mem_table >> "$OUT/memory.txt"
render_pngs
ls "$OUT"
