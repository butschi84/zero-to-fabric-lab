# Phase 2 — L2VNI over EVPN/VXLAN

**Shows:** one bridged segment (tenant corp, VLAN 101, L2VNI 10101, EVI 101,
RT 65000:10101, subnet 10.1.1.0/24) stretched over three leafs. Underlay as in
phase 1 (eBGP, ECMP, BFD). Overlay: iBGP EVPN in AS 65500 (`local-as`, global
AS not prepended) from every leaf loopback to both spines, which are route
reflectors; the BGP next hop of Type-2/3 routes stays the originating leaf.
BUM traffic uses **ingress replication** (Type-3 / IMET routes, no multicast
underlay). **ARP suppression** with SR Linux proxy-ARP: IP/MAC pairs learned
locally are advertised in Type-2 MAC/IP routes, remote leafs answer ARP from
that table. Fabric links run IP MTU 9000 on a 9232-byte port MTU; hosts 1500.

**Used by:** article 3; videos C1-C5. Shots P2-01..P2-13.

```
           spine1  spine2          (route reflectors, AS 65000 / overlay 65500)
        /     |   X   |    \
     leaf1   leaf2   leaf3         (VTEPs 10.255.0.11/.12/.13)
     |   \   /  |      |
 client1 mobile client2 client3    10.1.1.11 / .13 / .12 / .14
```

`mobile` (02:00:00:00:10:13) is cabled to leaf1 and leaf2; only one link is up
at a time, so moving it means moving the host (MAC mobility, P2-10).

## Run

```sh
make deploy PHASE=p2-l2vni
make evidence PHASE=p2-l2vni     # ~3 min; toggles MTU and proxy-ARP, then restores
make destroy PHASE=p2-l2vni
```

## Evidence (`evidence/p2-l2vni/`)

| Shot | Content |
|---|---|
| P2-00 | `containerlab graph` web page (PNG) |
| P2-01 | VTEP / VNI overview (vxlan-interface detail, mac-vrf EVPN config) |
| P2-02 | BGP sessions incl. the EVPN family on the overlay sessions |
| P2-03 | Type-3 (IMET) routes per remote VTEP |
| P2-04 | Type-2 route in detail after the first ping (RD, RT, VNI label, next hop, cluster list) |
| P2-05 | MAC tables on leaf1 and leaf2: learnt vs evpn |
| P2-06 | VXLAN packet decoded headless with tshark (outer Eth/IP/UDP 4789/VNI, inner Eth/IP/ICMP), pcap included |
| P2-07 | MTU test with DF bit, underlay IP MTU 1500 vs 9000 (`mtu.csv`) |
| P2-08 | ARP suppression: ARP requests seen on a bystander VTEP with and without proxy-ARP (pcaps) |
| P2-09 | one broadcast -> one VXLAN copy per remote VTEP (ingress replication) |
| P2-10 | MAC mobility: Type-2 before/after the move, sequence number 1 |
| P2-11 | proxy-ARP table of leaf2: IP/MAC pairs learned locally vs via EVPN |
| P2-12 | overlay session: capabilities and EVPN AFI/SAFI counters |
| P2-13 | ping matrix across the three leafs |

## Measured

- MTU (P2-07): with underlay IP MTU 1500 the largest ping payload with DF is
  **1422 bytes** (1450-byte packet + 50 bytes VXLAN = 1500); with IP MTU 9000
  it is **1472** (host MTU 1500). Oversized frames are dropped silently: the
  bridging leaf cannot send "fragmentation needed".
- ARP suppression (P2-08): 0 ARP requests reach the bystander VTEP with
  proxy-ARP, 1 without (one per request that is flooded).
- Ingress replication (P2-09): 1 broadcast -> 2 unicast VXLAN copies (two remote VTEPs).
- RAM: ~1.5 GiB per SR Linux node, 5 nodes ~7.5 GiB (`memory.txt`).

## Known limits / findings

- Do not set `proxy-arp evpn flood unknown-arp-req false`: ARP for a host the
  fabric has not learned yet is then never flooded, and the host stays
  unreachable until it speaks first (seen during the build).
- Hosts in clab get MTU 9500 on their veths by default; this phase sets 1500
  explicitly, otherwise the MTU test measures the wrong thing.
