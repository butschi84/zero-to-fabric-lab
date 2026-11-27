# Phase 4 — load balancing: ECMP, anycast VIP by BGP, HAProxy + keepalived

**Shows:** three ways to spread load, side by side, in the service rack
(VRF `shared`, VLAN 901 / 10.9.1.0/24, stretched over leaf2 and leaf3):

1. **Fabric ECMP** (hash over the 5-tuple, SR Linux defaults).
2. **Anycast VIP by BGP:** `srv1` (leaf2), `srv2` and `srv3` (leaf3) are FRR
   + busybox httpd. Each holds `10.9.100.10/32` on `lo` and announces it by
   eBGP to the anycast gateway of its leaf (AS 65411-65413 to the leaf AS).
   leaf3 balances over its two servers (BGP multipath), every leaf sees the
   VIP behind leaf2 and leaf3 (Type-5, ECMP). A server that stops announcing
   drops out.
3. **HAProxy + keepalived:** `lb1` (leaf2) and `lb2` (leaf3) share the VRRP VIP
   `10.9.1.100` (VRID 100, priority 150/100, advert 1 s) and balance round
   robin over the same three servers with health checks.

Every server answers with its hostname and MAC, so the responder is visible.
Clients `corp1`/`corp2` sit in VRF corp on leaf1; the `shared` prefixes are
leaked into corp on leaf1 and corp into shared on leaf2/leaf3 (phase 3b
method).

**Used by:** article 5; video E1 (E1a/E1b). Shots P4-01..P4-06.

```
             spine1    spine2
           /    |    X    |    \
      leaf1         leaf2          leaf3
   corp1 corp2    srv1  lb1     srv2 srv3 lb2
                  \___ VLAN 901, VRF shared, 10.9.1.0/24 ___/
   anycast VIP 10.9.100.10 (srv1-3, BGP)    VRRP VIP 10.9.1.100 (lb1/lb2)
```

## Run

```sh
make deploy PHASE=p4-lb
make evidence PHASE=p4-lb       # ~5 min; pauses srv2 and lb1 and restores them
make destroy PHASE=p4-lb
```

## Evidence (`evidence/p4-lb/`)

| Shot | Content |
|---|---|
| P4-01 | VIP in leaf1's route table with two VTEP next hops, leaf3 with two server next hops, the server BGP sessions |
| P4-02 | 100 requests per client against the VIP: answers per server (`vip_distribution.csv`), hash options |
| P4-03 | HAProxy status (CSV view of the stats page), VRRP master/backup, VRRP adverts captured on lb2 (pcap), round robin |
| P4-04 | server failure in two variants (BGP shutdown vs. hung server), requests redistributing (`server_failover.csv`) |
| P4-05 | active balancer hangs: VRRP failover, ARP entry moved via EVPN, preempt back; 3 runs (`lb_failover.csv`) |
| P4-06 | `containerlab graph` web page (PNG) |

## keepalived / VRRP inside the EVPN fabric — what works, what does not

Tested here (SR Linux 24.10.7, EVPN-VXLAN, ingress replication):

- **Works:** VRRP adverts (multicast 224.0.0.18) are BUM traffic and reach the
  other balancer on another leaf through the L2VNI (P4-03). After a failover
  the new master's gratuitous ARP moves the VIP's IP/MAC binding; the leafs
  update their ARP/EVPN entry (`origin evpn`, P4-05) and traffic follows.
- **Takes time:** a hung master (`docker pause lb1`) is replaced after 3
  missed adverts plus skew: lb2 held the VIP after **2.7 / 3.6 / 3.6 s**
  (3 runs). The HTTP outage seen by a client was **4.1 / 6.6 / 8.6 s**: after
  keepalived, the IP/MAC move still has to reach the client's leaf (GARP ->
  ARP -> EVPN Type-2 / host route). That second part varied between 1.4 and
  5 s and we did not decompose it further. Preempting back (`unpause`) lost
  no request in all 3 runs (`lb_failover.csv`).
- **Prerequisite, not a given:** the balancers must share one L2 segment
  (a stretched L2VNI). In an L3-only design (one subnet per leaf) VRRP between
  racks is not possible; then the anycast VIP by BGP (variant 2) is the tool.
- **Not needed for the gateway:** the anycast gateway already makes the
  first hop redundant on every leaf; VRRP is only for service VIPs here.
- Not tested: VRRP with a virtual MAC (`use_vmac`), unicast VRRP, split brain
  when the fabric partitions.

## Findings / deviations

- **Leaf preference again:** without `preference ebgp 100` in the server
  VRF, leaf2 prefers leaf3's Type-5 copy of the VIP over its own server's
  route and stops advertising it (same effect as on the borders in phase 3b).
- A server that withdraws its route on purpose (BGP `neighbor shutdown`) lost
  no request. A hung server (`docker pause`, link up) is only removed when the
  BGP hold time expires (FRR datacenter defaults: keepalive 3 s, hold 9 s):
  requests hashed to it failed for up to ~6.5 s after the event, the others
  kept working (`server_failover.csv`). BFD would shorten the
  first case (vSR Linux minimum 1 s, see phase 1).
- RAM: 5 SR Linux nodes, ~7.7 GiB in total (`memory.txt`).
