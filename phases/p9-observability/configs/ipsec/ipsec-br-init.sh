#!/bin/sh
# ipsec-br: WAN ports at 1500 bytes, then addresses, VTIs, strongSwan
for i in eth2 eth3; do ip link set $i mtu 1500; done
exec /ipsec-init.sh "eth1=10.254.21.0/31 eth2=198.51.100.2/29 eth3=203.0.113.2/29" "vti1:1:198.51.100.2:198.51.100.1:10.252.1.2/30 vti2:2:203.0.113.2:203.0.113.1:10.252.2.2/30"
