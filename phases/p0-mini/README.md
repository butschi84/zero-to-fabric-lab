# Phase 0 — containerlab basics (mini topology)

**Shows:** how a lab is described (`topology.clab.yml`), deployed, inspected,
graphed and destroyed; what a node costs in RAM; a first ping across the
fabric. Routing is **static** and uses spine1 only: spine2 is cabled but idle,
which is the motivation for phase 1.

**Used by:** article 8 (containerlab), article 1; video E3. Shots P0-01..P0-07. P0-08 (MAC per hop): videos A1 / A4.

```
client1 -- leaf1 ==== spine1, spine2 ==== leaf2 -- client2
10.10.1.10   (e1-49 -> spine1, e1-50 -> spine2)   10.10.2.10
```

| Node | Loopback | Links |
|---|---|---|
| spine1/2 | 10.255.0.1 / .2 | e1-1 -> leaf1, e1-2 -> leaf2 |
| leaf1/2 | 10.255.0.11 / .12 | e1-49 -> spine1, e1-50 -> spine2, e1-1 -> client |
| links | 10.254.<spine>.0/31 (leaf1), .2/31 (leaf2) | spine even, leaf odd |

## Run

```sh
make deploy PHASE=p0-mini
make evidence PHASE=p0-mini   # deploys, measures, destroys and redeploys itself
make destroy PHASE=p0-mini
```

## Evidence (`evidence/p0-mini/`)

| Shot | Content |
|---|---|
| P0-01 | topology YAML (comments and client exec lines left out) |
| P0-02 | `containerlab deploy` node table |
| P0-03 | `clab graph` in the browser (PNG taken from the lab page only) |
| P0-04 | Docker VM size, RAM and CPU per node (cgroup) |
| P0-05 | ping + traceroute client1 -> client2, ICMP capture on leaf1 e1-49 (`.pcap`, P0-05b tshark) |
| P0-06 | deploy / destroy / redeploy wall-clock times |
| P0-07 | LLDP neighbours of leaf1 (cabling check) |
| P0-08 | what changes per hop: ARP and one ping client1 -> client2, captured at the same time on client1 eth1, leaf1 e1-49, spine1 e1-2 and client2 eth1 (`P0-08a..d` text, PNG and `.pcap`); P0-08 summary: the same echo request at the four points, new MAC pair on every link, IP addresses unchanged, TTL 64/63/62/61. Own script: `bash phases/p0-mini/evidence-p0-08.sh` (deploys if needed, empties every neighbour cache on the path while the captures run, does not destroy) |

## Known limits

- P0-04 shows the Docker VM size as text from `docker info` instead of a
  screenshot of the Docker Desktop settings window (no desktop screenshots).
- `docker stats` shows 0 B for SR Linux nodes; the cgroup value is used.
