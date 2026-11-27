#!/bin/sh
# Firewall data plane: sub-interfaces per tenant (VLAN = tenant number) to both
# border leafs, forwarding on, rp_filter off (ECMP over two borders is
# asymmetric by design), and a stateful rule set with counters. No NAT.
set -e
sysctl -qw net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0
ip addr add 10.250.0.1/31 dev eth3
# the container's management default route would win over the WAN default
ip route del default 2>/dev/null || true
for b in 1 2; do
  for t in 1 2 3 9; do
    ip link add link eth$b name eth$b.$t type vlan id $t
    ip addr add 10.250.$b.$((2 * t + 1))/31 dev eth$b.$t
    ip link set eth$b.$t up
    sysctl -qw net.ipv4.conf.eth$b/$t.rp_filter=0
  done
done
iptables -P FORWARD DROP
iptables -N TENANT-RULES
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -j TENANT-RULES
# tenants -> internet (WAN), no NAT
iptables -A TENANT-RULES -s 10.1.0.0/16 -o eth3 -j ACCEPT -m comment --comment "corp to WAN"
iptables -A TENANT-RULES -s 10.2.0.0/16 -o eth3 -j ACCEPT -m comment --comment "guest to WAN"
# shared services variant B: guest reaches the DNS service only through here
iptables -A TENANT-RULES -s 10.2.0.0/16 -d 10.9.1.53 -p udp --dport 53 -j ACCEPT -m comment --comment "guest to shared DNS"
iptables -A TENANT-RULES -s 10.2.0.0/16 -d 10.9.1.53 -p icmp -j ACCEPT -m comment --comment "guest ping shared DNS"
iptables -A TENANT-RULES -j LOG --log-prefix "fw-drop " -m limit --limit 5/s
iptables -A TENANT-RULES -j DROP -m comment --comment "everything else"
