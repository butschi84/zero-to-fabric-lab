#!/bin/sh
# ipsec-b: WAN ports at 1500 bytes, then addresses, VTIs, strongSwan
for i in eth2; do ip link set $i mtu 1500; done
exec /ipsec-init.sh "eth1=10.254.11.20/31 eth3=10.254.11.22/31 eth2=203.0.113.1/29" "vti2:2:203.0.113.1:203.0.113.2:10.252.2.1/30"
