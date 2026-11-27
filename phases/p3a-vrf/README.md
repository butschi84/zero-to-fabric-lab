# Phase 3a — tenants as VRFs, symmetric IRB, anycast gateway, DHCP relay

**Shows:** three tenants as IP-VRFs on SR Linux, each with its own L3VNI
(symmetric IRB): `corp` (L3VNI 50001), `guest` (50002) and `mgmt` (50003; the
VRF is called `mgmt-net` on the switches because SR Linux reserves the name
`mgmt` for its own management instance). Every network has an anycast gateway
`10.<tenant>.<net>.1` with the same virtual MAC `00:00:5e:00:01:01`
(virtual-router-id 1) on every leaf. DHCP for corp network 01 is relayed by
every leaf with option 82 and a **unique giaddr per leaf**
(`10.1.255.<leaf id>` on `lo1.1` in VRF corp), so the server's reply returns to
the leaf that asked, not to whichever leaf owns the shared gateway address.

**Used by:** article 4; videos D1-D3. Shots P3a-00..P3a-09.

```
             spine1   spine2                 (RR, AS 65000 / overlay 65500)
          /     |    X    |     \
      leaf1       leaf2         leaf3        (VTEPs .11 / .12 / .13)
   corp1 guest1  corp2 guest2   srv3  dhcpsrv
   dhcp1         dhcp2 mgmt2
```

| Tenant | VRF (SR Linux) | L3VNI | RT | Networks (VLAN / L2VNI / subnet) | Leafs |
|---|---|---|---|---|---|
| corp | corp | 50001 | 65000:50001 | 101 / 10101 / 10.1.1.0/24; 102 / 10102 / 10.1.2.0/24 | 1-3; 3 |
| guest | guest | 50002 | 65000:50002 | 201 / 10201 / 10.2.1.0/24 | 1-2 |
| mgmt | mgmt-net | 50003 | 65000:50003 | 301 / 10301 / 10.3.1.0/24 | 2 |

RDs are auto-derived from the EVI: IP-VRF EVI = tenant number, so
`<loopback>:<tenant>`; MAC-VRF EVI = VLAN, so `<loopback>:<VLAN>`.

## Run

```sh
make deploy PHASE=p3a-vrf
make evidence PHASE=p3a-vrf      # ~2.5 min; toggles a wrong RT and restores it
make destroy PHASE=p3a-vrf
```

## Evidence (`evidence/p3a-vrf/`)

| Shot | Content |
|---|---|
| P3a-00 | `containerlab graph` web page (PNG) |
| P3a-01 | VRF list and the corp route table on leaf1 (rack 1) and leaf3 (rack 3) |
| P3a-02 | Type-5 (prefix, label = L3VNI) and Type-2 MAC/IP (label = L2VNI) routes, one Type-5 in detail with RT and router MAC |
| P3a-03 | anycast gateway: same IP and MAC on leaf1 and leaf2, both hosts resolve the same MAC |
| P3a-04 | symmetric IRB in a capture: corp1 -> srv3 across racks inside VNI 50001, inner MACs are router MACs (pcap included) |
| P3a-05 | isolation: guest cannot reach corp (ping, guest route table without any corp prefix) |
| P3a-06 | DHCP relay: DISCOVER/OFFER/REQUEST/ACK at the server with giaddr and option 82, leases on two leafs (pcap included) |
| P3a-07 | numbering register (VRF, VNI, EVI, RD, RT per leaf) read from the running state |
| P3a-08 | RT mismatch: wrong export RT on leaf3; the RR holds the route, leaf1 drops it, with `keep-all-routes` it is received but not imported |
| P3a-09 | ping matrix: inside a tenant OK, across tenants FAIL |

## Findings / deviations

- **No RFC 3527 link-selection in SR Linux 24.10.7.** The DHCP relay offers
  option 82 suboptions `circuit-id` and `remote-id` only (YANG enum). The
  lab therefore uses ISC Kea 2.6 as server and selects the pool by relay
  address (`relay.ip-addresses` = the leafs' giaddrs). A server that only
  matches giaddr against its subnets would find no pool for `10.1.255.11`.
- `circuit-id` format is `<leaf>|<vrf>|<irb>|<vlan>:<tag>`, e.g.
  `leaf1|corp|irb0|101:0`; `remote-id` is the client MAC.
- **RT mismatch is silent at the leaf.** A leaf keeps no EVPN route that no
  local VRF imports (route-target filtering), so the wrong route is visible on
  the route reflector, not on the leaf. `afi-safi evpn evpn keep-all-routes
  true` makes it visible on the leaf for troubleshooting.
- SR Linux reserves `mgmt`; the DHCP relay also refuses any network-instance
  whose name starts with `mgmt` as relay target (YANG must-statement).
- Overlay convergence after deploy: ~60-90 s until all EVPN sessions carry
  routes; `evidence.sh` waits for it.
- RAM: 5 SR Linux nodes ~7.5 GiB (`memory.txt`).
