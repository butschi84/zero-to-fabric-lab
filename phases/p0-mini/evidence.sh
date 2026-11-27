#!/usr/bin/env bash
# Phase 0 evidence: deploy, node table, graph, resources, first ping, destroy.
# This script deploys and destroys the lab itself (it measures both).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB=ztf-p0 OUT="$HERE/../../evidence/p0-mini"
source "$HERE/../../scripts/lib.sh"
rm -f "$OUT"/P0-0[1-7]*.txt "$OUT"/P0-0[1-7]*.png "$OUT"/P0-0[1-7]*.pcap   # P0-08: evidence-p0-08.sh
CLAB="$REPO_ROOT/scripts/clab.sh"
cd "$HERE"
"$CLAB" destroy -t topology.clab.yml --cleanup >/dev/null 2>&1 || true
strip() { sed -e 's/\x1b\[[0-9;]*m//g'; }

yaml_excerpt() { grep -v '^ *#' topology.clab.yml | grep -v '^$' | grep -vE 'exec:|ip (addr|route)' | sed -n '1,30p'; }
shot P0-01 topology-yaml host "cat phases/p0-mini/topology.clab.yml   (comments and client exec lines left out)" yaml_excerpt

t0=$(date +%s.%N); "$CLAB" deploy -t topology.clab.yml 2>&1 | strip | sed "s|$REPO_ROOT|.|g" > "$OUT/deploy.log"; t1=$(date +%s.%N)
deploy_s=$(echo "$t1 - $t0" | bc)
deploy_tbl() { grep -E '^[│╭├╰┌└+|]' "$OUT/deploy.log" | sed -n '1,28p'; }
shot P0-02 clab-deploy host "containerlab deploy -t topology.clab.yml" deploy_tbl

wait_srl spine1 spine2 leaf1 leaf2
sleep 5
res() {
  echo "Docker VM: $(docker info --format '{{.NCPU}} CPUs, {{.MemTotal}} bytes RAM, {{.OperatingSystem}}, {{.Architecture}}, kernel {{.KernelVersion}}')"
  echo
  mem_table
  echo
  echo "method: memory.current of each container cgroup, after boot; cpu from docker stats"
}
shot P0-04 resources host "docker info; cat /sys/fs/cgroup/memory.current per node" res

# P0-05: first ping across the fabric (static routes via spine1) + ICMP capture.
pcap leaf1 e1-49 8 P0-05-icmp-leaf1-e1-49.pcap icmp
sleep 2
ping5() { hx client1 ping -c 5 -i 0.5 10.10.2.10; echo; hx client1 traceroute -I -N 1 -n -w1 -q1 10.10.2.10; }
shot P0-05 first-ping client1 "ping -c 5 10.10.2.10 ; traceroute -I 10.10.2.10" ping5
pcap_wait
pcap_text P0-05-icmp-leaf1-e1-49.pcap P0-05b-icmp-capture.tmp -n
{ printf '# P0-05b · leaf1 e1-49 · %s\nhost# tshark -r P0-05-icmp-leaf1-e1-49.pcap -n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; head -12 "$OUT/P0-05b-icmp-capture.tmp"; } > "$OUT/P0-05b-icmp-capture.txt"
rm -f "$OUT/P0-05b-icmp-capture.tmp"

lldp() { srlt leaf1 "show system lldp neighbor" "Name,Neighbor System Name,Neighbor Port" | grep -v mgmt0; }
shot P0-07 lldp-neighbors leaf1 "show system lldp neighbor   (front ports)" lldp

graph_export "$HERE/topology.clab.yml"

t0=$(date +%s.%N); "$CLAB" destroy -t topology.clab.yml --cleanup >/dev/null 2>&1; t1=$(date +%s.%N)
destroy_s=$(echo "$t1 - $t0" | bc)
t0=$(date +%s.%N); "$CLAB" deploy -t topology.clab.yml >/dev/null 2>&1; t1=$(date +%s.%N)
redeploy_s=$(echo "$t1 - $t0" | bc)
wait_srl spine1 spine2 leaf1 leaf2
t2=$(date +%s.%N); ready_s=$(echo "$t2 - $t0" | bc)
times() {
  echo "method: wall clock of each containerlab command on this Mac (images already pulled)"
  printf '%-34s %8.1f s\n' "deploy (first)" "$deploy_s" "destroy --cleanup" "$destroy_s" "deploy (again)" "$redeploy_s" "deploy until all SR Linux answer CLI" "$ready_s"
}
shot P0-06 deploy-destroy-times host "time containerlab deploy / destroy" times
render_pngs
ls "$OUT"
