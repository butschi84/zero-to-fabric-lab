#!/bin/sh
# ipsec-a: WAN ports at 1500 bytes, then addresses, VTIs, strongSwan
for i in eth2; do ip link set $i mtu 1500; done
exec /ipsec-init.sh "eth1=10.254.1.20/31 eth3=10.254.1.22/31 eth2=198.51.100.1/29" "vti1:1:198.51.100.1:198.51.100.2:10.252.1.1/30"
