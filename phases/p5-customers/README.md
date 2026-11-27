# Phase 5 — hosting customers with overlapping addresses

**Shows:** two hosting customers whose networks are **identical**:
`cust-a` and `cust-b` both use `10.0.0.0/24` with gateway `10.0.0.1`, and
`a-vm1`/`b-vm1` even share `10.0.0.10`. Each customer is one IP-VRF with its
own L3VNI (cust-a 50011, cust-b 50012; VLAN 1101/1201, L2VNI 11101/11201),
so every lookup stays inside the customer. Every VM answers HTTP with its own
name and MAC, so the responding machine is visible.

- `ce-a`: customer A's own router (FRR, AS 64611) on a routed port of leaf2
  in VRF cust-a; eBGP, the leaf accepts 192.168.0.0/16 (/24+) with a
  **prefix limit of 5** and sends the customer its fabric subnet.
- **Shared service** (DNS 10.9.1.53, VRF shared, leaf2) for both customers
  through `border1` and a **firewall**. Because both customers arrive as
  10.0.0.10, the firewall maps each customer 1:1 to its own range
  (cust-a -> 100.64.11.0/24, cust-b -> 100.64.12.0/24, `NETMAP`) and routes
  replies back by connection mark per customer (policy routing, no kernel
  VRF needed). Border VRFs use static routes to the firewall.
- **Onboarding:** `tools/onboard.py` generates a new customer from the same
  plan as all startup configs; `c-vm1` (also 10.0.0.10) is cabled to leaf1
  e1-5 and comes alive when cust-c is committed (P5-06).

**Used by:** article 6; video E2 (E2a/E2b). Shots P5-00..P5-07.

```
              spine1   spine2
            /    |   X   |    \
       leaf1        leaf2        border1 -- fw (NETMAP per customer)
   a-vm1 b-vm1   a-vm2 b-vm2       VRFs cust-a, cust-b, shared
   c-vm1 (P5-06) ce-a svc-dns
   all 10.0.0.x: a-vm1 = b-vm1 = c-vm1 = 10.0.0.10, a-vm2 = b-vm2 = 10.0.0.20
```

## Run

```sh
make deploy PHASE=p5-customers
make evidence PHASE=p5-customers   # ~1.5 min; adds/removes a leak, onboards cust-c, floods the CE session
make destroy PHASE=p5-customers
```

## Evidence (`evidence/p5-customers/`)

| Shot | Content |
|---|---|
| P5-00 | `containerlab graph` web page (PNG) |
| P5-01 | two VRFs with the same 10.0.0.0/24, both gateways answer, 10.0.0.20 answered by a-vm2 resp. b-vm2 |
| P5-02 | BGP session to ce-a: state, received routes, what the CE receives, the prefix limit |
| P5-03 | isolation matrix (A vs. B, CE-A, shared DNS) with the responder's name and MAC, route counts, firewall counters |
| P5-03b | deliberate leak as negative evidence: CE-A's prefix leaked into cust-b; B's requests reach A's router, the replies land at A's own 10.0.0.10 (pcaps) |
| P5-04 | both customers query the shared DNS via border1 + firewall; the service sees 100.64.11.10 and 100.64.12.10 (pcap), NAT and filter counters |
| P5-05 | customer register (VRF, VNI, EVI, RD, RT) read from the running state, before cust-c is onboarded |
| P5-06 | onboarding cust-c by script: generated lines, config diff, time until its VM reaches the gateway; generated CLI in `P5-06-onboard-cust-c.cli` |
| P5-07 | prefix limit: CE announces 12 > 5 prefixes, leaf tears the session down; recovers when the CE stops (evidence regenerated 2026-11-26: the "after" line now says the session has no row instead of printing an empty table) |

## Measured

- Onboarding cust-c on one leaf: 43 generated CLI lines, commit **0.5 s**,
  c-vm1 reached its gateway **0.5 s** after the start (run of 2026-11-26 19:07 UTC;
  the first run measured 0.6 s).
- Prefix limit: the session goes to Idle with `MAXPREFIX_EXCEEDED`, comes back
  at once and is torn down again (ce-a counted 10-20 Cease notifications in
  ~8 s, varies per run), i.e. it flaps until the CE stops; `prevent-teardown false` is the
  default. Once the CE announces 2 prefixes again it stays up.
- RAM: 5 SR Linux nodes, ~7.5 GiB in total (`memory.txt`).

## Findings / deviations

- **A leak with overlapping addresses does not even work as a leak:**
  leaking A's 192.168.10.0/24 into B gives B a route to A's network, B's
  packets arrive at A's router, and A's router answers 10.0.0.10 *inside
  customer A*. The isolation is broken (B can send into A) and the replies go
  to a machine that never asked. Exactly what the article warns about.
- A shared service for customers with the same addresses needs translation
  somewhere; here it is the firewall (NETMAP per customer + connection-mark
  routing). Without it, the service could not tell the customers apart.
- No re-start interval after a prefix-limit teardown was configured; the
  session flaps at protocol speed. On real gear configure an idle/restart
  timer or `prevent-teardown` with a warning.
