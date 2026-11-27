#!/usr/bin/env bash
# Background traffic for phase 9, so the dashboards show living curves:
# UDP flows between tenant hosts of both sites and the branch, each with its own
# slow ramp (a small "day": sine with a 10-minute period, shifted per flow) plus
# noise. Peaks stay far below line rate. Cheap: a few MB of RAM in the clients.
#   bash load.sh start | stop | status
set -euo pipefail
LAB=ztf-p9
c() { echo "clab-${LAB}-$1"; }
# name  source  destination  port  base  amplitude  phase   (Mbit/s)
# peaks kept low on purpose: emulated links in Docker Desktop queue early, and more load
# turns into probe jitter rather than prettier curves
FLOWS="corp-stretched a-c1 10.1.1.21 5401 1 6 0.0
corp-dci a-c2 10.1.3.21 5402 1 8 1.6
corp-back b-c3 10.1.2.11 5403 0.5 4 3.1
branch-corp br-c1 10.1.2.11 5404 0.5 3 4.4
branch-guest br-g1 10.2.1.11 5405 0.3 2 5.5"
server() { # destination host -> container
  case "$1" in 10.1.1.21) echo b-c1;; 10.1.3.21) echo b-c3;; 10.1.2.11) echo a-c2;; 10.2.1.11) echo a-g1;; esac; }

start() {
  while read -r name src dst port base amp ph; do
    docker exec "$(c "$(server "$dst")")" sh -c "iperf3 -s -D -p $port" >/dev/null 2>&1 || true
    docker exec -d "$(c "$src")" sh -c "echo \$\$ > /tmp/load-$name.pid; while true; do
      r=\$(awk -v t=\$(date +%s) -v b=$base -v a=$amp -v p=$ph 'BEGIN{srand(); printf \"%.1f\", b + a*(0.5+0.5*sin(6.2832*t/600+p)) + rand()*a*0.15}')
      iperf3 -u -c $dst -p $port -b \${r}M -l 1200 -t 50 >/dev/null 2>&1 || sleep 5; done"
    echo "started $name: $src -> $dst:$port, $base..$(awk -v b=$base -v a=$amp 'BEGIN{print b+a*1.15}') Mbit/s"
  done <<< "$FLOWS"
}
stop() {
  while read -r name src dst port _; do
    docker exec "$(c "$src")" sh -c "kill \$(cat /tmp/load-$name.pid) 2>/dev/null; pkill -f '[i]perf3 -u -c $dst -p $port'; true" 2>/dev/null || true
    docker exec "$(c "$(server "$dst")")" sh -c "pkill -f '[i]perf3 -s -D -p $port'; true" 2>/dev/null || true
  done <<< "$FLOWS"; echo "load stopped"
}
status() { while read -r name src _; do printf '%-16s %s\n' "$name" "$(docker exec "$(c "$src")" sh -c "pgrep -f '[i]perf3 -u' >/dev/null && echo running || echo idle")"; done <<< "$FLOWS"; }
case "${1:-start}" in start) start;; stop) stop;; status) status;; *) echo "usage: $0 start|stop|status" >&2; exit 2;; esac
