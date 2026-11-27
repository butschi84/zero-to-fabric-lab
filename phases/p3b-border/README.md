# Phase 3b — border leafs, firewall, WAN, Type-5 default, shared services

**Shows:** the north-south path. Two border leafs (`border1` AS 65201,
`border2` AS 65202, loopbacks .21/.22) carry every tenant VRF as IP-VRF only
and peer per VRF over a VLAN sub-interface with a **Linux firewall** (FRR +
iptables, AS 65300, VLAN = tenant number). A **WAN router** (FRR, AS 64900)
sends the firewall a default route; the firewall passes exactly that default
to every tenant VRF, and the borders advertise it into the fabric as an EVPN
**Type-5 0.0.0.0/0** with themselves as next hop (ECMP over both borders).
The default exists in the fabric only while the firewall learns it from the
WAN (P3b-05). **No NAT**; tenant prefixes are routed to the WAN as they are.

**Shared services** (DNS `10.9.1.53` in VRF `shared`, L3VNI 50009, on leaf3)
in both variants, at the same time:
- **A, route leaking in the fabric** for corp: leaf1 copies `10.9.1.0/24`
  (and longer) from VRF shared into corp, leaf3 copies corp's `10.1.0.0/16`
  prefixes into shared (`inter-instance-policies`). Default routes are never
  leaked; leaked routes are not re-advertised into EVPN.
- **B, through the firewall** for guest: guest has only the default route, so
  it reaches DNS via border -> firewall (rule "guest to shared DNS", counters)
  -> border -> leaf3.

**Used by:** article 4; video D4 (D4a/D4b). Shots P3b-01..P3b-06.

```
                 wan (198.51.100.1 = "internet")
                  |
                 fw  (eth1.t -> border1, eth2.t -> border2, t = 1,2,3,9)
               /    \
         border1    border2              (IP-VRFs corp, guest, mgmt-net, shared)
             |   X   |
          spine1   spine2
             |   X   |
          leaf1     leaf3
       corp1 guest1  svc-dns mgmt3
```

| Link | Addressing |
|---|---|
| border<b> - fw, tenant t | 10.250.<b>.<2t>/31 (border) / .<2t+1> (fw), VLAN t |
| fw - wan | 10.250.0.1 / 10.250.0.0 |
| shared DNS | 10.9.1.53 (VLAN 901, L2VNI 10901, L3VNI 50009) |

## Run

```sh
make deploy PHASE=p3b-border
make evidence PHASE=p3b-border    # ~1.5 min; takes the WAN link down and up again
make destroy PHASE=p3b-border
```

## Evidence (`evidence/p3b-border/`)

| Shot | Content |
|---|---|
| P3b-01 | Type-5 0.0.0.0/0 per VRF (RD per border and VRF, label = L3VNI) and the default in each VRF's route table with both borders as next hops |
| P3b-02 | firewall rule set with counters after traffic to the WAN (corp, guest) and a blocked guest -> corp attempt |
| P3b-03 | route leaking: prefix-set, inter-instance policies, leaked prefixes in corp (leaf1) and shared (leaf3), nothing on the border |
| P3b-04 | DNS from corp (variant A, leaked, no firewall) and guest (variant B, firewall counters) |
| P3b-05 | WAN failure: default gone from the fabric and back, times in `wan_failover.csv` |
| P3b-06 | `containerlab graph` web page (PNG) |

## Measured

- WAN link down on the firewall -> 0.0.0.0/0 gone from leaf1's VRF corp:
  **min 5.3 / median 7.5 / max 8.4 s**; back after the link returns: **3.2 /
  4.7 / 6.0 s** (5 runs, poll resolution ~0.5 s, `wan_failover.csv`). Lab
  times on one laptop, not hardware.
- RAM: 6 SR Linux nodes, ~9.0 GiB in total (`memory.txt`).

## Findings / deviations

- **Route leaking by import-RT policy did not work** on SR Linux 24.10.7: an
  IP-VRF `bgp-vpn import-policy` that accepts another tenant's RT
  (`target:65000:50009`) leaves the foreign Type-5 routes `Rejected_Route`
  (visible only with `keep-all-routes`). Leaking is therefore done locally on
  the leaf with `inter-instance-policies`; the leaf carries the source VRF
  without ports. Community sets default to `match-set-options all`.
- **Border preference:** without `preference ebgp 100` in the border VRFs,
  each border prefers the other border's Type-5 copy (both 170) over its own
  firewall route, so only one border advertises the default. With it: ECMP.
- **Container default route:** the firewall's Docker management default
  route outranks a BGP default (kernel, distance 0); it is deleted at start.
- **TTL across the fabric:** a traceroute shows only the gateway and the
  target; the firewall sees the probe sent with TTL 2 arriving with TTL 253.
  The virtual SR Linux does not carry the host's TTL through the VXLAN hop, so
  fabric and firewall hops stay invisible to traceroute here. The firewall
  counters prove the path instead.
- SR Linux reserves VRF names starting with `mgmt` (see phase 3a), hence
  `mgmt-net`.
