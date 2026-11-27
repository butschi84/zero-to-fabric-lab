# Zero to Fabric — a reproducible EVPN/VXLAN enterprise-network lab

Companion lab for the OpenSight series *"Zero to Fabric: Moderne Firmennetze
verstehen"* (articles and a video course). Every phase is a self-contained
[containerlab](https://containerlab.dev) topology with startup configs per
node, a `make deploy`/`make destroy`, and an evidence script that reproduces
the outputs, captures and measurements used in the articles and videos.

The series has **10 articles** and **more than 30 videos** (A6, D4, E1, E2,
E4, E5, E6 and E7 are split into an a and a b part). Phase 9 (observability)
belongs to **article 10**, "Observing the fabric" (videos E7a/E7b), not to
article 9.

Network OS: **Nokia SR Linux** (fabric) and **FRR** (routers outside the
fabric), Alpine Linux containers for clients and servers (`ztf-tools`, with
ISC Kea for DHCP) and for router-like Linux roles (`ztf-frr`: FRR plus
iptables, HAProxy, keepalived, strongSwan). Everything runs on
one laptop; it was built and measured on an Apple Silicon Mac (arm64) with
Docker Desktop.

## Phases

| Phase | Directory | Shows | Status |
|---|---|---|---|
| 0 | `phases/p0-mini` | containerlab basics: 2 spines, 2 leafs, 2 clients, static routes | done |
| 1 | `phases/p1-underlay` | eBGP underlay (RFC 7938), ECMP, BFD, spine failure, BGP deep dive (FRR test peers) | done |
| 2 | `phases/p2-l2vni` | EVPN/VXLAN L2VNI, Type 2/3, ingress replication, MTU, ARP suppression, MAC mobility | done |
| 3a | `phases/p3a-vrf` | VRFs, L3VNI, symmetric IRB, anycast gateway, DHCP relay (option 82, unique giaddr), RT mismatch | done |
| 3b | `phases/p3b-border` | border leafs, firewall (FRR + iptables), WAN, Type-5 default, shared services via leaking and via firewall | done |
| 4 | `phases/p4-lb` | load balancing: ECMP, anycast VIP via BGP from FRR servers, HAProxy + keepalived (VRRP across the fabric) | done |
| 5 | `phases/p5-customers` | customer VRFs with overlapping IPs, customer CE with prefix limit, deliberate leak, shared service via NAT firewall, onboarding script | done |
| 6 | `phases/p6-multihoming` | ESI multihoming (LACP, all-active, DF, aliasing), failure tests in four variants | done |
| 8 | `phases/p8-multisite` | two sites with two gateways each, DCI variant B (eBGP-EVPN, next hop unchanged), WAN netem, stretched L2 vs L3; branch (SR Linux, VRFs as L3VNIs) over IPsec (strongSwan), two WAN paths, gateway and site failure, anycast service failover | done |
| 9 | `phases/p9-observability` | phase 8 watched out of band: gNMI -> gnmic -> OTLP, syslog, probes, IPsec counters, a collector per site managed by LinkMesh (OpAMP), Prometheus, Loki, Grafana dashboard as code; link / MAC / MTU / site-cut faults with detection times | done |
| 7 | – | Clabernetes on Kubernetes | later |

Each phase directory has its own README (what it shows, which article and
videos use it, how to run it, known limits).

## Quick start

```sh
make tools                         # builds the ztf-tools:1 and ztf-frr:1 images (Alpine)
make deploy   PHASE=p1-underlay    # ~20-30 s on an M-series Mac
make evidence PHASE=p1-underlay    # writes evidence/p1-underlay/
make destroy  PHASE=p1-underlay
```

`scripts/clab-graph.sh` serves the interactive `containerlab graph` page on
http://127.0.0.1:50080 (port published, works on Docker Desktop). Graph PNGs
in `evidence/` are screenshots of that page only, taken in a separate,
signed-out browser profile.

Only one phase runs at a time (they share the management network
`ztf-mgmt`, 172.30.30.0/24). `scripts/clab.sh` runs containerlab from its
official image, so nothing but Docker is needed on the host:

```sh
docker run --rm -it --privileged --network host --pid host \
  -v /var/run/docker.sock:/var/run/docker.sock -v /var/run/netns:/var/run/netns \
  -v "$PWD:$PWD" -w "$PWD" ghcr.io/srl-labs/clab:0.83.0 containerlab <cmd>
```

## Requirements and measured resources

- Docker (Linux, or Docker Desktop on macOS/Windows), arm64 or amd64.
- RAM: **about 1.5 GiB per SR Linux node** (measured 1,47-1,53 GiB, cgroup
  `memory.current`), Linux hosts below 20 MiB. Phase 0 needs ~6 GiB, phase 1
  (with the FRR test peers) ~6.1 GiB, phases 2-5 ~7.5-9 GiB. Give Docker at least 8 GiB, 16-20 GiB for the
  later phases; phase 8 (9 SR Linux nodes) needs ~13 GiB for the lab, phase 9
  adds ~0.6 GiB for the observability stack. See `evidence/*/memory.txt`.
- Disk: SR Linux image ~2.9 GB, FRR ~0.3 GB, clab ~0.3 GB.

## Pinned images (all with a linux/arm64 and linux/amd64 manifest)

| Image | Version | Why this one |
|---|---|---|
| `ghcr.io/nokia/srlinux` | 24.10.7 | 25.10.5 and 26.7.2 crash `net_inst_mgr` at boot under Docker Desktop (see below) |
| `quay.io/frrouting/frr` | 10.7.1 | current stable |
| `ghcr.io/srl-labs/clab` | 0.83.0 | current release |
| `alpine` | 3.22 | base of `images/ztf-tools` |

## Addressing and numbering (all phases)

| What | Scheme | Example |
|---|---|---|
| Loopback (system0) | 10.255.0.<id>/32; spines 1-2, leafs 11-16, borders 21-22 | leaf1 = 10.255.0.11 |
| Spine-leaf link | /31 per link, 10.254.<spine>.<2(n-1)> spine side, +1 leaf side | spine1-leaf2 = 10.254.1.2 / .3 |
| Underlay ASN | spines share 65000, leaf N = 651NN, borders 65201-65202 | leaf3 = 65103 |
| Overlay | iBGP EVPN, AS 65500, spines are route reflectors | |
| VLAN | 100 x tenant + net (corp 1, guest 2, mgmt 3, shared 9) | corp clients = 101 |
| L2VNI / L3VNI | 10000 + VLAN / 50000 + tenant | 10101 / 50001 |
| Route target | 65000:<VNI> | 65000:10101 |
| Route distinguisher | <loopback>:<VLAN or tenant> (SR Linux auto-RD = system IP:EVI) | 10.255.0.11:101 |
| Tenant subnet | 10.<tenant>.<net>.0/24, gateway .1 | 10.1.1.0/24 |

The SR Linux startup configs are generated from one plan,
`tools/gen_configs.py`, and committed (`make configs` regenerates them), so a
value cannot drift between phases.

## Evidence

`evidence/<phase>/` holds, per shot ID (`P<phase>-<nr>`):
`*.txt` (max ~30 lines, header with shot ID, node and UTC time),
`*.png` (the same text rendered as a dark 1920x1080 terminal, 120x30),
`*.pcap` (one flow, small), `raw/` (full-width SR Linux output),
`failover.csv` (machine-readable measurements), `memory.txt`, and the
topology graph (`*.mermaid`, `*.dot`). Compact tables are produced from
SR Linux's own `| as json` output (`tools/srl_table.py`); values are never
edited. Packet views are decoded headless with `tshark` (no GUI screenshots).

## Known limits of this environment

- **SR Linux 25.10/26.7 on Docker Desktop:** `sr_net_inst_mgr` asserts with
  `File exists (17) ... creating veth "gway-2800", "gateway" pair` and every
  commit touching a network-instance fails. 24.10.7 runs cleanly. (Observed
  on Docker Desktop with linuxkit kernels 6.12 and 7.0; not tested on a
  plain Linux host.)
- **BFD minimum 1 s:** the virtual SR Linux overrides lower intervals
  (`override to minimum 1000000us`), so BFD detection is 3 x 1 s here.
  Hardware goes down to a few milliseconds.
- **No kernel VRF in Docker Desktop's kernel** (`CONFIG_NET_VRF` unset): FRR
  is used only for roles without VRFs (WAN, customer CE, servers).
- The graph web view's "Vertical Layout" ignores `graph-level` labels in
  clab 0.83; the PNGs use the default force layout.
- Docker Desktop reports 0 B memory for SR Linux nodes in `docker stats`
  (they share a netns sidecar); `memory.txt` reads the cgroup instead.

## Licences

Lab code, configs and evidence: Apache License 2.0 (see `LICENSE`). The
repository contains no container images, only references to them:

- **Nokia SR Linux** (`ghcr.io/nokia/srlinux`): published by Nokia free of charge
  on the public GitHub container registry for learning, demo, test and CI use;
  pulled by whoever runs the lab, under Nokia's terms.
- **FRR** (`quay.io/frrouting/frr`): GPL-2.0. **containerlab**: BSD-3-Clause.
- **LinkMesh server** (`docker.io/opensight/linkmesh-server`, phase 9): OpenSight's
  product, Community tier, pulled from Docker Hub.
- **OpenTelemetry Collector contrib + OpAMP supervisor** (built in
  `images/ztf-collector` from the upstream releases): Apache-2.0.
- **gnmic** (Apache-2.0), **Prometheus**, **Grafana**, **Loki** (AGPL-3.0 for
  Grafana and Loki), **smokeping_prober**, **Alpine** packages: their own licences.

All credentials in the repository (SR Linux `admin` / `NokiaSrl1!`, the IPsec
PSK, the LinkMesh and Grafana lab admin) are lab-only values for containers on
your own machine; never reuse them.
