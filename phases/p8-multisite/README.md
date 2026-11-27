# Phase 8 — multiple sites: two data centres and a branch

**Status: done (P8-01..P8-20, plus P8-17a).** Part 1 (two fabrics, DCI, WAN)
and part 2 (branch with VRFs over IPsec, two WAN paths, gateway and site
failure, service failover) run in one topology and one evidence script.

**Shows:** two small fabrics joined over a WAN, and a branch office joined to
both over IPsec. Site A (`spine-a`, `leaf-a1`, `gw-a`, `gw-a2`) keeps the
numbering of phases 1-6 (loopbacks 10.255.0.x, overlay AS 65500); site B
(`spine-b`, `leaf-b1`, `gw-b`, `gw-b2`) mirrors it (10.255.1.x, spine AS 65010,
leaf AS 65111, gateways 65211/65212, overlay AS 65510). The branch is page 2:
`br1` = 10.255.2.11, AS 65120, overlay AS 65520. Tenants, VLANs, VNIs and RTs are
the same everywhere. Configs (SR Linux, FRR, strongSwan): `tools/gen_p8.py`.

```
 branch:  br-c1 (corp) br-g1 (guest) - br1 (SR Linux) - ipsec-br (strongSwan + FRR)
                                                          |  WAN 1 (ISP 1)    |  WAN 2 (ISP 2)
                                                        wan1                wan2
                                                          |                   |
 site A:  a-c1 a-c2 a-g1 srv-a - leaf-a1 - spine-a - gw-a/gw-a2 + ipsec-a     |
                                                     ==== wan (DCI) ====      |
 site B:  b-c1 b-c3 srv-b ----- leaf-b1 - spine-b - gw-b/gw-b2 + ipsec-b ------+
```

- **DCI variant built: B.** The border gateways exchange EVPN routes by
  **eBGP-EVPN across the WAN** (`dci` group, multihop between loopbacks, full mesh
  of the 2 x 2 gateways) and leave the **next hop unchanged**; underlay eBGP over
  the WAN carries the loopbacks. VXLAN runs **end to end, leaf to leaf**; the VNI
  is not translated and the gateways do not re-originate routes (P8-04, P8-06).
  Variant A (RFC 9014 gateway with re-origination) was not built.
- Networks: corp 01 (VLAN 101, 10.1.1.0/24) is **stretched** over both sites;
  corp 02 (10.1.2.0/24) only in A, corp 03 (10.1.3.0/24) only in B, guest 01
  (10.2.1.0/24) only in A. Branch: corp 10.1.10.0/24, guest 10.2.10.0/24.
- **Branch router = SR Linux** (`br1`), because FRR has no kernel VRF on Docker
  Desktop. It is a VTEP of its own: VRFs corp and guest are **L3VNIs 50001 /
  50002** (EVPN Type 5) to all four gateways (`hubs` group, eBGP multihop, next
  hop unchanged). LANs are routed sub-interfaces directly in the VRFs; no L2
  leaves the branch.
- **IPsec = strongSwan 5.9.14 in Linux containers** (`ztf-frr` image: kernel
  ESP/xfrm, IKEv2, AES-GCM-256, PSK), route-based with one **VTI per WAN path**.
  FRR on the IPsec boxes carries only the underlay (loopbacks) through the
  tunnels; the VRFs ride inside as VXLAN. So it is **one tunnel per WAN path with
  an overlay on top**, not one tunnel per VRF.
- **Two independent WAN paths:** WAN 1 (`wan1`, 198.51.100.0/29) to the
  concentrator `ipsec-a` in site A is primary (local-pref 200 in, AS-path
  prepend x3 out on WAN 2); WAN 2 (`wan2`, 203.0.113.0/29) to `ipsec-b` in site B
  is the backup. Only the branch's own loopbacks go into the tunnels, so the
  branch never becomes a transit between the sites. FRR BFD 3 x 300 ms on the
  tunnels.
- **Anycast service:** `srv-a` (site A) and `srv-b` (site B) both announce VIP
  10.9.100.10/32 by eBGP to their leaf in VRF corp (as phase 4); srv-b prepends
  its AS twice, so A serves while it is up.

## Run

```sh
make deploy PHASE=p8-multisite     # 9 SR Linux nodes, ~13 GiB RAM
make evidence PHASE=p8-multisite   # ~8 min. The LAST tests stop site A
make destroy PHASE=p8-multisite    # destroy afterwards
```

## Evidence (`evidence/p8-multisite/`)

| Shot | Content |
|---|---|
| P8-01 | topology YAML excerpt (site B, WAN nodes, branch) and `containerlab graph` PNG of all three sites |
| P8-02 | gw-a sessions: underlay over the WAN and to ipsec-a, overlay to the RR, DCI to both B gateways, branch; site B loopbacks reachable |
| P8-03 | DCI sessions (EVPN) and each site's view of the other site's prefixes |
| P8-04 | next hop in the other site = originating leaf, RD/RT/VNI unchanged, AS path shows the other overlay AS |
| P8-05 | L3 between sites: ping, traceroute, route table |
| P8-06 | packet on the WAN decoded (outer leaf -> leaf, UDP 4789, VNI 50001, inner packet), pcap |
| P8-07 | MTU over the WAN with DF: WAN ip-mtu 1500 vs 9000 (`wan_mtu.csv`), ICMP at the host |
| P8-08 | `containerlab tools netem set/show` on the WAN ports towards site B |
| P8-09 | latency before / with / after impairment (`wan_latency.csv`), DCI session state |
| P8-10 | stretched VNI: same subnet in both sites, MAC of B's client in A's table behind leaf-b1 |
| P8-11 | ARP broadcasts leaving site A: stretched vs L3-only network (pcaps) |
| P8-12 | broadcast flood at 100 pps in A, received rate in B (`broadcast_flood.csv`) |
| P8-13 | branch router: VRF list, route table per VRF, isolation test guest vs corp |
| P8-14 | tunnel state: IKE/ESP SAs (`swanctl --list-sas`), version, FRR sessions per tunnel, br1's EVPN sessions, VRF-to-tunnel mapping |
| P8-15 | tunnel overhead from captures (pcaps), DF MTU table through the tunnel (`tunnel_mtu.csv`), TCP with and without MSS adjustment (`tcp_mss.csv`) |
| P8-16 | WAN 1 fails and comes back: loss, routes before/during/after, BFD; with SR Linux's default and with a 1 s advertisement interval (`branch_failover.csv`) |
| P8-17a | one of site A's two gateways stopped: site B and branch keep reaching A (`site_failure.csv`) |
| P8-17 | site A fails completely: routes in B, ping loss B <-> branch, branch moves to WAN 2 (`site_failure.csv`) |
| P8-18 | service failover: branch client reaches the anycast VIP in B after A fails (`service_failover.csv`) |
| P8-19 | gw-b BGP/BFD log during P8-17 |
| P8-20 | memory with all three sites running (`memory.txt`) |

## Measured (run of 2026-11-26, 19:50-19:58 UTC)

- MTU between the sites: with the gateways' WAN ip-mtu at 1500 the largest DF
  ping is a **1450-byte** IP packet (1422 payload); at 9000 a full 1500 passes.
  **No ICMP "fragmentation needed" reached the host** (0 packets).
- Impairment 30 ms delay, 5 ms jitter, 1 % loss towards site B: RTT avg 0.79 ->
  30.3 ms (max 35.8), 0 of 50 lost in this run; DCI sessions stayed established.
- Broadcasts: 3 ARP requests in the stretched VNI -> **9** VXLAN packets on the
  WAN (three VTEPs of VNI 10101 in site B: leaf-b1, gw-b, gw-b2); in the
  site-local network **0**. A 100 pps flood in A arrives in B at **~100 pps**
  (101) when stretched, **0** when L3-separated. (With one gateway per site, part 1
  measured 6: each extra gateway that carries the stretched MAC-VRF costs one
  more copy of every broadcast across the WAN.)
- Branch isolation: guest -> corp (site A and branch) 0 of 3; guest -> guest in
  site A 3 of 3; corp -> corp 3 of 3.
- **Tunnel overhead, from the captures:** host packet 1028 bytes -> VXLAN 1078
  (**+50**) -> ESP on WAN 1 1132 (**+54**, AES-GCM tunnel mode): **104 bytes** in
  total. Largest DF packet a branch host gets through: **1396 bytes** (1368
  payload); the IPsec box's path MTU for the VXLAN packet is 1446. ipsec-br sends
  ICMP "too big" to br1 (6 in the sweep), **none reaches the host**.
- **TCP through the tunnel (iperf3, 4 s): default MSS 1448 -> 0 bytes in both
  directions** (black hole: the host is never told). MSS 1356 (= 1396 - 40):
  41.3 Mbit/s branch -> DC, 40.9 Mbit/s DC -> branch (lab numbers, laptop CPU).
- **WAN 1 failover** (100 % loss on ISP 1, links up): BFD on the tunnel goes down,
  ipsec-br's route to site A moves from vti1 to vti2 and back on restore.
  Largest gap with SR Linux's default `minimum-advertisement-interval` (5 s):
  **9.2 s** in this run (2.6 s and 10.4 s in two earlier runs of the same test);
  with 1 s on all SR Linux BGP groups: **2.9 s** (1.6 s earlier). Failback: 0-1
  lost packet. The backup path crosses several SR Linux hops, and each waits up
  to the advertisement interval before passing on the new route.
- **One gateway of site A stopped (P8-17a):** site B -> A **2.9 s** gap, branch
  -> A **2.8 s** (BFD 3 x 1 s); A stays reachable through gw-a2.
- **Site A down (P8-17):** leaf-b1's routes with a site A next hop 8 -> 0;
  site B -> branch **2.6 s** gap (the branch moves from WAN 1 to WAN 2), inside
  site B **no loss** (largest gap 34 ms).
- **Service failover (P8-18):** a new HTTP connection every 50 ms from the
  branch to the anycast VIP: before srv-a 60/60, after srv-b 260/260, 8 failed
  requests, longest gap **4.1 s**; br1's VIP route moved from leaf-a1 to leaf-b1.
  No DNS change and no health checker involved.
- RAM: 9 SR Linux nodes + 15 Linux containers **~13.0 GiB** (13 284 MiB, P8-20).

## Findings / deviations

- **The gateway must import what it passes on.** An SR Linux node that is not a
  route reflector keeps EVPN routes no local VRF imports only with
  `keep-all-routes`, and even then marks them `Rejected_Route` and does not
  advertise them. The gateways therefore carry the IP-VRFs corp and guest (no
  interfaces) and the MAC-VRF of the stretched network (no ports, no IRB).
- **No MAC-VRF for site-local networks on the gateway**: with one, the gateway
  becomes a VTEP of that network and its broadcasts cross the WAN.
- eBGP needs explicit policies (`accept-all`) for the DCI and branch groups;
  without them SR Linux sends and accepts nothing (`ebgp-default-policy`).
- An IRB on the gateway for a remote network made it advertise that subnet
  itself (black hole) - avoided by design.
- **strongSwan's `bypass-lan` plugin breaks route-based IPsec:** it installs
  bypass policies for every connected subnet, including the /30 inside the VTI,
  so BGP over the tunnel was never encrypted and the VTI dropped it (tx carrier
  errors). Disabled in `strongswan.conf`. Docker Desktop's kernel has no XFRM
  interfaces (`type xfrm` unknown), VTI works.
- **No MSS clamping in the path.** SR Linux 24.10.7 has `tcp-mss` only for its
  own BGP sessions, not for transit traffic, and the IPsec box sees only VXLAN,
  so iptables `TCPMSS` cannot reach the inner TCP header. The MSS was therefore
  set at the client (`iperf3 -M`, i.e. TCP_MAXSEG). On real gear this belongs on
  the branch router (e.g. `ip tcp adjust-mss`) or the hosts' MTU is lowered.
- **A stopped SR Linux node keeps its links up:** its network namespace lives in
  a sidecar container, so `docker stop` does not take the veth peers down.
  Failure is only detected by BFD; without BFD on the gateway <-> concentrator
  links the branch lost 7.6 s in a trial run (FRR hold time 9 s). BFD now runs
  on every link (SR Linux minimum 1 s).
- **SR Linux's `minimum-advertisement-interval` defaults to 5 s** (range 1-255,
  0 is refused). It dominates failover times on multi-hop paths (see P8-16).
- **Second gateway per site: built** (`gw-a2`, `gw-b2`). A gateway failure is
  survived (P8-17a); P8-17 is now a real site failure (all of site A), not a
  property of a single-gateway build. Cost: +2 SR Linux nodes (~3 GiB) and one
  more VXLAN copy per broadcast in the stretched VNI.
- The IPsec concentrators are single boxes per site (`ipsec-a`, `ipsec-b`); a
  failure of `ipsec-a` alone is handled like WAN 1 failing (backup over WAN 2).
- Lab secret: the PSK in `configs/ipsec/*.swanctl.conf` is for this lab only.
