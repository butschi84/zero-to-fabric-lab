#!/bin/sh
# IPsec box: addresses, one VTI per tunnel (key = strongSwan mark), charon.
# usage: ipsec-init.sh "<if>=<addr> ..." "<vti>:<key>:<local>:<remote>:<addr> ..."
set -e
sysctl -qw net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0
ip route del default 2>/dev/null || true
for a in $1; do ip addr add "${a#*=}" dev "${a%%=*}"; done
for t in $2; do
  IFS=: read -r name key local remote addr <<EOF
$t
EOF
  ip link add "$name" type vti local "$local" remote "$remote" key "$key"
  ip addr add "$addr" dev "$name"
  ip link set "$name" up
  sysctl -qw "net.ipv4.conf.$name.disable_policy=1" "net.ipv4.conf.$name.rp_filter=0"
done
ipsec start >/dev/null 2>&1
for _ in $(seq 1 50); do [ -S /var/run/charon.vici ] && break; sleep 0.2; done
swanctl --load-all >/var/log/swanctl-load.log 2>&1
