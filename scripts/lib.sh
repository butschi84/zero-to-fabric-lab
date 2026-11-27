#!/usr/bin/env bash
# Shared helpers for the per-phase evidence scripts.
# Source it after setting LAB (containerlab lab name) and OUT (evidence dir).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_IMAGE="${TOOLS_IMAGE:-ztf-tools:1}"
: "${LAB:?set LAB}" "${OUT:?set OUT}"
mkdir -p "$OUT"

c() { echo "clab-${LAB}-$1"; }

# Run a command and record it as a transcript: a prompt line, then the output.
# usage: rec <file> <node> <prompt-cmd> <command...>
rec() {
  local file="$1" node="$2" shown="$3"; shift 3
  { printf '%s# %s\n' "$node" "$shown"; "$@" 2>&1 || true; printf '\n'; } >> "$OUT/$file"
}

# SR Linux CLI command (non-interactive)
srl() { local n="$1"; shift; docker exec "$(c "$n")" sr_cli -d "$*"; }
# FRR vtysh command
vtysh() { local n="$1"; shift; docker exec "$(c "$n")" vtysh -c "$*"; }
# Linux host command
hx() { local n="$1"; shift; docker exec "$(c "$n")" "$@"; }

srl_rec() { local f="$1" n="$2"; shift 2; rec "$f" "$n" "$*" srl "$n" "$*"; }
frr_rec() { local f="$1" n="$2"; shift 2; rec "$f" "$n" "$*" vtysh "$n" "$*"; }
hx_rec()  { local f="$1" n="$2"; shift 2; rec "$f" "$n" "$*" hx "$n" "$@"; }

# Wait until an SR Linux node answers CLI commands.
wait_srl() {
  local n; for n in "$@"; do
    for _ in $(seq 1 120); do
      srl "$n" "info from state system information version" >/dev/null 2>&1 && break
      sleep 2
    done
  done
}

# Wait until a condition command succeeds (max seconds).
wait_for() { local max="$1"; shift; for _ in $(seq 1 "$max"); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }

# Ping matrix: rows = sources, cols = destinations (name=ip). Result: OK/FAIL.
# usage: ping_matrix <file> "src1 src2" "name1=ip1 name2=ip2" [ping-args]
ping_matrix() {
  local file="$1" srcs="$2" dsts="$3" extra="${4:-}" s d name ip
  {
    printf '%-10s' "src\\dst"; for d in $dsts; do printf '%-14s' "${d%%=*}"; done; printf '\n'
    for s in $srcs; do
      printf '%-10s' "$s"
      for d in $dsts; do
        ip="${d#*=}"
        if docker exec "$(c "$s")" ping -c 3 -i 0.2 -W 1 $extra "$ip" >/dev/null 2>&1; then
          printf '%-14s' "OK"; else printf '%-14s' "FAIL"; fi
      done; printf '\n'
    done
  } > "$OUT/$file"
}

# Capture packets inside a node's network namespace with tcpdump.
# usage: pcap <node> <interface> <seconds> <outfile.pcap> <bpf filter...>
# Runs in the background; call `wait` (or pcap_wait) before reading the file.
pcap() {
  local n="$1" ifc="$2" secs="$3" file="$4"; shift 4
  docker run --rm -d --name "ztf-cap-$$-$RANDOM" --net "container:$(c "$n")" \
    -v "$OUT:/out" "$TOOLS_IMAGE" \
    timeout "$secs" tcpdump -i "$ifc" -nn -U -s 0 -w "/out/$file" "$@" >/dev/null
}
# Capture on both fabric uplinks of a leaf (ECMP may use either) and merge
# into one file with the real outer Ethernet header.
# usage: pcap_uplinks <leaf> <seconds> <out.pcap> <bpf...>   then pcap_wait; pcap_merge <out.pcap>
pcap_uplinks() {
  local n="$1" secs="$2" file="$3"; shift 3
  pcap "$n" e1-49 "$secs" "${file%.pcap}.e1-49.part" "$@"
  pcap "$n" e1-50 "$secs" "${file%.pcap}.e1-50.part" "$@"
}
pcap_merge() {
  local file="$1"
  docker run --rm -v "$OUT:/out" "$TOOLS_IMAGE" mergecap -w "/out/$file" "/out/${file%.pcap}.e1-49.part" "/out/${file%.pcap}.e1-50.part"
  rm -f "$OUT/${file%.pcap}".e1-*.part
}
pcap_wait() { while docker ps --format '{{.Names}}' | grep -q '^ztf-cap-'; do sleep 1; done; }

# Decode a pcap headless (text, never a GUI screenshot).
# usage: pcap_text <file.pcap> <outfile> [tshark args]
pcap_text() {
  local file="$1" outf="$2"; shift 2
  docker run --rm -v "$OUT:/out" "$TOOLS_IMAGE" tshark -r "/out/$file" "$@" > "$OUT/$outf" 2>/dev/null || true
}

# Measure the interruption of a ping stream across an event.
# usage: outage <src-node> <dst-ip> <label> <event-cmd...>
# Pings every 10 ms, runs the event after 3 s, keeps pinging 12 s more,
# and reports lost packets and the largest gap between replies.
outage() {
  local src="$1" dst="$2" label="$3"; shift 3
  docker exec -d "$(c "$src")" sh -c "ping -D -i 0.01 -W 1 -w 15 $dst > /tmp/outage-$label.txt 2>&1"
  sleep 3; "$@"; sleep 13
  docker exec -i "$(c "$src")" python3 - "$label" "/tmp/outage-$label.txt" <<'PY'
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
}

# Append outage() result lines to a CSV (machine-readable for charts).
# usage: outage_csv <file.csv> <method> <line...>
outage_csv() {
  local f="$OUT/$1" method="$2"; shift 2
  [ -f "$f" ] || echo "test,sent,received,lost,loss_ms_at_10ms_interval,largest_reply_gap_ms,method" > "$f"
  local l; for l in "$@"; do
    echo "$l" | sed -E 's/^([^:]+): sent=([0-9]+) received=([0-9]+) lost=([0-9]+) loss_time~([0-9]+) ms.*largest_reply_gap=([0-9]+) ms/\1,\2,\3,\4,\5,\6/' | sed "s|\$|,\"$method\"|" >> "$f"
  done
}

# Memory per lab container, read from the container cgroup (docker stats
# reports 0 for SR Linux nodes, which share a netns sidecar container).
mem_table() {
  printf '%-22s %10s %8s\n' "node" "mem_MiB" "cpu_%"
  local cname n mem cpu
  for cname in $(docker ps --format '{{.Names}}' | grep "^clab-${LAB}-" | grep -v -- '-netns$' | sort); do
    n="${cname#clab-${LAB}-}"
    mem=$(docker exec "$cname" cat /sys/fs/cgroup/memory.current 2>/dev/null || echo 0)
    cpu=$(docker stats --no-stream --format '{{.CPUPerc}}' "$cname" 2>/dev/null | tr -d '%')
    printf '%-22s %10d %8s\n' "$n" "$((mem / 1048576))" "${cpu:-n/a}"
  done
}

# Write one shot: a header (shot id, node, UTC time), the prompt line and the
# output, max ~30 lines. usage: shot <ID> <slug> <node> <shown-cmd> <cmd...>
shot() {
  local id="$1" slug="$2" node="$3" shown="$4"; shift 4
  local _shotf="$OUT/${id}-${slug}.txt"
  { printf '# %s · %s · %s\n' "$id" "$node" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ "$shown" != "-" ] && printf '%s# %s\n' "$node" "$shown"
    "$@" 2>&1 || true; } > "$_shotf"
  local n; n=$(wc -l < "$_shotf"); [ "$n" -gt 32 ] && echo "WARN: $_shotf has $n lines" >&2
  return 0
}

# Full-width raw output for reference (not for video), under raw/.
raw() {
  local name="$1" node="$2" cmd="$3"; mkdir -p "$OUT/raw"
  { printf '# %s · %s\n%s# %s\n' "$node" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$node" "$cmd"; srl "$node" "$cmd" 2>&1 || true; } > "$OUT/raw/$name.txt"
}

# SR Linux show command rendered as a compact table from its JSON output.
# usage: srlt <node> "<show cmd>" "Col1,Col2" [Col=value filter]
srlt() { local n="$1" cmd="$2" cols="$3"; shift 3; srl "$n" "$cmd | as json" | python3 "$REPO_ROOT/tools/srl_table.py" "$cols" "$@"; }

render_pngs() { python3 "$REPO_ROOT/tools/render_term.py" "$OUT"/P*.txt >/dev/null; }

# Topology graph exports (mermaid + graphviz dot) from the topology file.
graph_export() {
  local topo="$1"
  ( cd "$(dirname "$topo")" && "$REPO_ROOT/scripts/clab.sh" graph -t "$(basename "$topo")" --mermaid --mermaid-direction LR >/dev/null 2>&1 || true
    "$REPO_ROOT/scripts/clab.sh" graph -t "$(basename "$topo")" --dot >/dev/null 2>&1 || true )
  local d; d="$(dirname "$topo")/clab-${LAB}/graph"
  [ -d "$d" ] && cp "$d"/* "$OUT/" 2>/dev/null || true
}

# Tenant register of one SR Linux node, read from its state (phase 3a+).
vrf_register() {
  local n="$1" d; d=$(mktemp -d)
  srl "$n" "info from state network-instance * protocols bgp-vpn | as json" > "$d/vpn.json"
  srl "$n" "info from state network-instance * protocols bgp-evpn bgp-instance 1 vxlan-interface | as json" > "$d/evpn.json"
  srl "$n" "info from state network-instance * protocols bgp-evpn bgp-instance 1 evi | as json" > "$d/evi.json"
  python3 - "$d/evpn.json" "$d/evi.json" <<'PY'
import json, sys
a, b = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
evi = {n["name"]: n["protocols"]["bgp-evpn"]["bgp-instance"][0].get("evi") for n in b.get("network-instance", [])}
for n in a.get("network-instance", []):
    n["protocols"]["bgp-evpn"]["bgp-instance"][0]["evi"] = evi.get(n["name"])
json.dump(a, open(sys.argv[1], "w"))
PY
  srl "$n" "info from state tunnel-interface vxlan1 vxlan-interface * ingress vni | as json" > "$d/tun.json"
  srl "$n" "info from state network-instance * type | as json" > "$d/type.json"
  python3 "$REPO_ROOT/tools/vrf_register.py" "$n" "$d/vpn.json" "$d/evpn.json" "$d/tun.json" "$d/type.json"
  rm -rf "$d"
}
cfg() { printf 'enter candidate\n%s\ncommit now\n' "$2" | docker exec -i "$(c "$1")" sr_cli >/dev/null; }

# HTTP failover probe (phase 4+): a new connection every 50 ms from <client>
# for <dur> s; <event-cmd> runs at <at> s. Prints tools/http_probe.py summary.
# usage: probe <client> <url> <dur> <at> <event-cmd...>
probe() {
  local cl="$1" url="$2" dur="$3" at="$4"; shift 4
  local f; f=$(mktemp)
  docker exec -i "$(c "$cl")" python3 - "$url" "$dur" 0.05 0.5 "$at" < "$REPO_ROOT/tools/http_probe.py" > "$f" &
  local pid=$!; sleep "$at"; "$@" >/dev/null 2>&1 || true; wait $pid; cat "$f"; rm -f "$f"
}
