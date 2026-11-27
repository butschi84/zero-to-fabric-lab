# Phase 1 — eBGP underlay, ECMP, BFD, spine failure

**Shows:** an RFC 7938 underlay: spines share AS 65000, every leaf has its
own AS (65101, 65102). One eBGP session per /31 link, IPv4 unicast, the leaf
loopbacks and client subnets are advertised, BGP multipath uses both spines
(ECMP). BFD on every session. Leafs tag what they originate with the community
`<leaf-AS>:<rack>`. Clients are routed at the leaf (10.10.1.0/24, 10.10.2.0/24).

**Used by:** article 2; videos B1-B3, A6 (A6a/A6b), A7. Shots P1-01..P1-05, P1-07..P1-12.

## Run

```sh
make deploy PHASE=p1-underlay
make evidence PHASE=p1-underlay   # ~4 min, includes failure tests
make destroy PHASE=p1-underlay
```

## Evidence (`evidence/p1-underlay/`)

| Shot | Content |
|---|---|
| P1-01 | BGP neighbours on leaf1 and spine1, all established |
| P1-02 | ASN / loopback table, read from the configs |
| P1-03 | route to leaf2's loopback with two next hops (ECMP) |
| P1-04 | 32 TCP flows client1 -> client2, packet counters per uplink |
| P1-05 | spine failure: a) both spine links down (`ip link set down` in the spine's namespace), b) silent failure (netem 100 % loss, links stay up). Ping every 10 ms from client1 to client2; the spine carrying that ping is the one failed. Routes before/during. Values also in `failover.csv` |
| P1-06 | `containerlab graph` web page (PNG, lab page only) |
| P1-07a | all sessions established (underlay + test peers) |
| P1-07b | TCP 179 blocked on ext2 (iptables), session bounced: stays `active`, reason + timestamped events |
| P1-07c | ext3 expects AS 65199: leaf1 gets NOTIFICATION Open Message Error / Bad Peer AS, retries every few s (FRR + SR Linux events) |
| P1-07d | both repaired, all established again |
| P1-08 | negotiated timers: leaf1 90 s vs ext1 180 s -> 90/30 on both sides; capabilities; message counters (FRR) |
| P1-09a | best path for 203.0.113.0/24 from three candidates: A ext1 LP 100 [64501], B ext2 LP 200 [64502 64510 64511], C ext3 LP 200 [64503 64512] -> C wins, tie-break reasons shown |
| P1-09b | LOCAL_PREF of C lowered to 50 -> B wins |
| P1-10 | address families of an underlay session (IPv4 unicast only; EVPN in P2-02/P2-12) |
| P1-11a | 198.51.100.0/24 with 64500:100 + large 64500:1:100 on spine1 and leaf2 |
| P1-11b | rule on leaf2 reads the community -> LOCAL_PREF 150; NO_EXPORT variant: spine1 keeps it, leaf2 never receives it |
| P1-12 | ping matrix and traceroute |

Test peers `ext1`-`ext3` (FRR 10.7.1, AS 64501-64503) hang off leaf1
ethernet-1/3..5 (10.253.<n>.0/31). Their prefix never enters the underlay
(`reject-all` export, import accepts only 203.0.113.0/24). Every change in
P1-07..P1-11 is reverted inside the evidence script, so the lab ends as
deployed. P1-06 is the `containerlab graph` page (force layout, no ASN
labels: the web view has no label option; ASNs are in P1-02).

## Measured (this Mac, see `failover.csv`)

- hard failure (links down): 0-1 ping lost, largest gap ~0.2 s
- silent failure (netem): ~2.4-2.7 s interruption = BFD 3 x 1 s detection

## Known limits

- The virtual SR Linux enforces a **1 s BFD minimum** (lower values are
  overridden), so silent failures take ~3 s here; on hardware BFD runs at
  tens of milliseconds.
- In P1-05 the number of sent pings in the silent test is lower than 1500
  because `ping` waits on lost replies; the interruption is the largest gap
  between replies, which is what the table reports.
