# Phase 6 — operations: EVPN multihoming and failure tests

**Shows:** a server (`srv-mh`, 10.1.1.50) attached to **two leafs with one
LACP bond** (802.3ad, fast rate, layer3+4 hash). leaf1 and leaf2 present the
same **Ethernet Segment** (ESI `00:11:22:33:44:55:66:77:88:01`, all-active)
and the same LACP system id/key (`00:00:00:00:11:11`, key 11), so the server
sees one partner. Remote leafs reach the server MAC via the ESI and balance
over both leafs (**aliasing**, `ecmp 2` in the MAC-VRF). Then one thing at a
time fails while `cl3` on leaf3 pings the server every 10 ms.

**Used by:** article 7; video E4 (E4a/E4b). Shots P6-00..P6-05.

```
          spine1    spine2
         /   |    X   |   \
     leaf1     leaf2      leaf3
        \     /             |
       srv-mh (bond0,      cl3 (measures)
       one ESI, all-active)
```

## Run

```sh
make deploy PHASE=p6-multihoming
make evidence PHASE=p6-multihoming   # ~4 min. The LAST test stops leaf1 (docker stop):
make destroy PHASE=p6-multihoming    # destroy afterwards, the lab is not restored
```

## Evidence (`evidence/p6-multihoming/`)

| Shot | Content |
|---|---|
| P6-00 | `containerlab graph` web page (PNG) |
| P6-01 | Ethernet segment: ESI, mode, DF election (algorithm `default` = modulo, DF = leaf2), Type-1 (per EVI and per ES) and Type-4 routes, the server MAC pointing at the ESI (aliasing) |
| P6-02 | LAG/LACP state on both leafs (same system id and key) and the server's bond (one aggregator, one partner) |
| P6-03 | failure table with method line (`failover.csv`): LAG member down, spine hangs, leaf hangs, leaf stopped |
| P6-04 | before / 12 s into each failure: Type-1 next hops, leaf1's loopback in the underlay, the overlay session |
| P6-05 | BGP/BFD event log with time stamps during "leaf1 hangs" |

## Measured (lab times, one run per row, vSR Linux with BFD and LACP at 1 s)

| Failure | Method | Loss (ms), run 1 / run 2 |
|---|---|---|
| LAG member down on leaf1 | `interface ethernet-1/1 admin-state disable` | 4180 / 4790 |
| spine1 hangs | `docker pause spine1` | 2620 / 2610 |
| leaf1 hangs | `docker pause leaf1` (links stay up) | 3750 / 5770 |
| leaf1 stopped | `docker stop -t 0 leaf1` (all its links go down) | 3500 / 2760 |

Run 2 is the committed `failover.csv`; run 1 is the run before it on the same
build. The spread between runs is as large as the differences between
variants, so the table shows orders of magnitude, not precise values.
Border failure is not part of this phase (see phase 3b, P3b-05).

## Findings

- **Data plane before control plane:** when leaf1 hangs or stops, its Type-1
  routes stay in leaf3's table (P6-04): the overlay session runs via the route
  reflectors from loopback to loopback without BFD (hold time 90 s). Traffic
  recovers anyway, because the underlay withdraws leaf1's loopback after BFD
  (3 x 1 s) and leaf3 marks the VTEP unreachable (next-hop tracking, P6-05:
  `NH unreachable ... 10.255.0.11`). Mass withdrawal by Type-1 is only seen
  when leaf1 itself withdraws the ES (LAG member down).
- **LAG member down took the longest** here. A likely reason: disabling the
  SR Linux port does not drop the veth carrier on the server, so the bond
  keeps sending on that member until LACP times out (3 x 1 s). Not verified
  further; on hardware the link would drop.
- DF election: algorithm `default` (service-carving modulo); with one EVI the
  higher of the two (leaf2) is DF. The optional aliasing/backup handling and
  other implementations' DF algorithms are not compared (one software family).
- RAM: 5 SR Linux nodes, ~6.0 GiB at the end of the run (leaf1 stopped),
  ~7.5 GiB with all running.
