#!/bin/sh
# Firewall between the customers and the shared service, statically routed.
# Both customers use 10.0.0.0/24, so the service could not tell them apart and
# a reply could not find its way back. Each customer is therefore mapped 1:1
# to its own range (cust-a 100.64.11.0/24, cust-b 100.64.12.0/24, NETMAP), and
# replies are routed back per customer by connection mark, not by address.
set -e
sysctl -qw net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0
ip route del default 2>/dev/null || true
for t in 9 11 12; do
  ip link add link eth1 name eth1.$t type vlan id $t
  ip addr add 10.250.1.$((2 * t + 1))/31 dev eth1.$t
  ip link set eth1.$t up
  sysctl -qw net.ipv4.conf.eth1/$t.rp_filter=0
done
ip route add 10.9.1.0/24 via 10.250.1.18 dev eth1.9
for t in 11 12; do
  ip route add 10.0.0.0/24 via 10.250.1.$((2 * t)) dev eth1.$t table $t
  ip rule add fwmark $t table $t
done
# mark each connection by the customer side it came from, restore the mark on replies
iptables -t mangle -A PREROUTING -i eth1.11 -m conntrack --ctstate NEW -j CONNMARK --set-mark 11
iptables -t mangle -A PREROUTING -i eth1.12 -m conntrack --ctstate NEW -j CONNMARK --set-mark 12
iptables -t mangle -A PREROUTING -j CONNMARK --restore-mark
iptables -t nat -A POSTROUTING -o eth1.9 -m connmark --mark 11 -j NETMAP --to 100.64.11.0/24
iptables -t nat -A POSTROUTING -o eth1.9 -m connmark --mark 12 -j NETMAP --to 100.64.12.0/24
iptables -P FORWARD DROP
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -i eth1.11 -o eth1.9 -d 10.9.1.53 -j ACCEPT -m comment --comment "cust-a to shared DNS"
iptables -A FORWARD -i eth1.12 -o eth1.9 -d 10.9.1.53 -j ACCEPT -m comment --comment "cust-b to shared DNS"
iptables -A FORWARD -j DROP -m comment --comment "everything else (e.g. customer to customer)"
