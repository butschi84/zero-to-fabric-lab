# Phase 9 — observability of the fabric (gNMI, syslog, LinkMesh, Prometheus, Grafana)

**Shows:** the two-site fabric of phase 8, watched from outside over the
out-of-band management network with open standards. SR Linux streams state over
**gNMI**; **gnmic** turns it into **OTLP** for a **collector per site**; the
collectors also take **syslog** and scrape **active probes** and **IPsec
counters**, and deliver metrics to **Prometheus** and logs to **Loki** through a
**durable on-disk queue**. The collectors are **otelcol-contrib under the OpAMP
supervisor**, enrolled into a **LinkMesh** server in the lab, and get their whole
pipeline from LinkMesh; nothing is configured by hand in them. **Grafana** shows
fabric, underlay, overlay, tenants and sites from a dashboard kept as code.

**Used by:** article 10 ("Observing the fabric"); videos E7a/E7b; blog post on linkmesh.io. Shots P9-*.

**Base: phase 8** (9 SR Linux nodes, both sites, branch over IPsec). It fits:
the whole phase uses ~12.2 GiB for the lab nodes plus ~0.6 GiB for the
observability stack (`memory.txt`); the Docker VM (19.5 GiB, which also runs two
kind clusters) keeps ~2.3 GiB available. No fallback to phase 5/6 was needed.

```
           NOC (out-of-band, 172.30.30.0/24)
  LinkMesh .200 ── OpAMP (config, health) ──┬───────────────┐
  Prometheus .210 <── OTLP/HTTP, durable ───┤               │
  Loki .212       <── queue on disk ────────┤               │
  Grafana .211                        collector-a .201  collector-b .202
                                       ^   ^    ^         ^   ^    ^
                         gnmic-a .203 ─┘   │    └scrape   │   │    └scrape probes, IPsec
                 gNMI 57400 ^      syslog 5514│           gnmic-b  syslog
              site A + branch (spine-a, leaf-a1, gw-a, gw-a2, br1)   site B (spine-b, leaf-b1, gw-b, gw-b2)
```

## Run

```sh
make deploy PHASE=p9-observability   # lab (~2 min) + obs/up.sh (LinkMesh, collectors, gnmic, Prometheus, Loki, Grafana)
make evidence PHASE=p9-observability # steady-state shots P9-01..P9-10
make load                            # background traffic: 5 UDP flows, slow ramps (10-min sine) + noise
make fault F=link                    # or mac | mtu | sitecut | wan | onchange | all  (before / during / after + detection time)
FAULT_GAP=720 make fault F=all       # the scenarios 12 min apart: each one stands alone in a 1-hour dashboard window
make load-stop; make destroy PHASE=p9-observability
```

Dashboards (as code, `obs/grafana/gen_*.py` -> `dashboards/*.json`):
**Fabric live** (`/d/ztf-fabric-live`, the hero: topology canvas, one row per layer,
few big numbers, 1920x1080) and **Fabric** (`/d/ztf-fabric`, the detailed one).
Every fault writes a Grafana annotation (tag `fault`). Colours come only from the
brand / video-kit tokens (`obs/grafana/tokens.py`): failures magenta, never red;
contrast measured by `obs/grafana/check_contrast.py` -> `dashboard-contrast.txt`.

External LinkMesh instead of the lab's own server (credentials from the environment only):
`LINKMESH_URL=https://... LINKMESH_TOKEN=... make deploy PHASE=p9-observability`
(or `LINKMESH_EMAIL` + `LINKMESH_PASSWORD`).

UIs (lab only, published on 127.0.0.1): LinkMesh http://127.0.0.1:18080
(admin@lab.local / ZeroToFabric-lab1), Grafana http://127.0.0.1:13000 (anonymous
viewer; admin / ZeroToFabric-lab1), Prometheus http://127.0.0.1:19090.

## Pieces

| Piece | Where | Note |
|---|---|---|
| SR Linux syslog + sFlow | `tools/gen_p9.py` -> `configs/*.cli` | p8 configs + remote syslog (mgmt, UDP 5514, RFC 5424) to the site collector, sFlow 1:1000, WAN IP MTU 9000 as healthy baseline |
| gNMI subscriptions | `obs/gnmic/gnmic-{a,b}.yaml` | interfaces (state, octets, errors, discards), BGP sessions + routes per AFI, BFD, EVPN RIB entries per route type, VTEPs, MAC table statistics, VRF route counts; 5-15 s sampling; output `otlp` (gnmic 0.50.0, verified) |
| Collector image | `images/ztf-collector` | otelcol-contrib 0.165.0 + opampsupervisor 0.165.0, the LinkMesh collector image's composition (see limits) |
| LinkMesh | `obs/linkmesh/bootstrap.py` | sources (OTLP, syslog, Prometheus scrape), destinations (OTLP/HTTP to Prometheus and Loki, durable queue), one route per collector; written via the LinkMesh REST API, delivered over OpAMP |
| Probes | smokeping_prober in a-c1 and b-c1 | ICMP every 1 s to clients in the other site, the branch and the own site |
| IPsec | `obs/exporters/ipsec_exporter.py` | `swanctl --list-sas` -> IKE/child SA state and ESP bytes/packets, in the IPsec containers |
| Prometheus | `obs/prometheus/prometheus.yml` | OTLP receiver, out-of-order window 2 h (late samples from a buffering collector are accepted) |
| Grafana | `obs/grafana/gen_dashboard.py` -> `dashboards/fabric.json` | provisioned: overview, underlay, overlay, tenants, sites/WAN, syslog |
| Faults | `faults.sh` | link, mac, mtu, sitecut |

## Evidence (`evidence/p9-observability/`)

| Shot | Content |
|---|---|
| P9-01 | containers, addresses and data flow |
| P9-02 | gNMI paths subscribed |
| P9-03 | a live `gnmic get` against leaf-a1 |
| P9-04 | SR Linux syslog / sFlow / gNMI server config |
| P9-05 | sFlow on the wire (pcap, sample types) and LinkMesh's refusal of a netflow receiver |
| P9-06 | LinkMesh: collector fleet, sources, destinations, routes |
| P9-07 | the collector's effective config as delivered by LinkMesh (summary; full YAML in `linkmesh/`) |
| P9-08 | EVPN routes per type, VTEPs, MAC table sizes, routes per tenant VRF, from Prometheus |
| P9-09 | probe latency between the sites, IPsec SAs |
| P9-10 | syslog lines in Loki |
| P9-fault-link | spine-a -> gw-a link down: BGP/BFD, ECMP shift to gw-a2, detection time |
| P9-fault-mac | the same MAC in both sites: duplicate detection, syslog, detection time |
| P9-fault-mtu | WAN IP MTU 9000 -> 1500: throughput collapse, MSS effect, what the counters do (not) show |
| P9-fault-sitecut | site B's collector cut off from the NOC for ~2 min: buffering and late delivery |
| P9-grafana-*.png | dashboard in steady state and before / during / after each fault |
| P9-linkmesh-*.png | LinkMesh UI: collectors, health, routing, dashboard |
| `detection.csv` | detection times, machine-readable |
| `memory.txt` | RAM of the phase |

## Known limits / findings

- **Detection times:** `detection.csv` holds the reference values (idle lab, no
  recording). `detection-long-run.csv` and `P9-fault-*-long-run.txt` are the same
  scenarios after 2-3 h with `make load` and Chrome screen recording running at the
  same time: detection then reads 45-80 s, mostly the Mac being busy (the injection's
  own `docker run`, the browser), while the telemetry itself stayed 2-3 s fresh.
  Under load the MTU fault is harder to see in WAN totals, because the background
  UDP (1200-byte datagrams) still fits after the cut; the 8 TCP flows collapse.
- **WAN latency on Docker Desktop:** with background load the A->B RTT shows
  periodic spikes of up to ~1 s at the load peaks (emulated links queue early).
  `P9-wan-latency-jitter.txt` (netem 30 ms / 5 ms): RTT 1.1 -> 31.7 -> 1.4 ms.
- **gNMI ON_CHANGE vs SAMPLE 30 s:** first `down` after 0.6 s vs 25.5 s
  (`P9-onchange-vs-sample.txt`).

- **Collector image:** `docker.io/opensight/linkmesh-collector:0.153.0` is not
  anonymously pullable yet, so `images/ztf-collector` builds the same composition
  from the upstream releases. It uses **0.165.0**, which LinkMesh 1.501.1
  recommends; 0.153.0 is flagged in the LinkMesh UI for advisory
  GHSA-vf52-ppm4-c35w. **opampsupervisor 0.165.0 refuses to start with
  `reports_remote_config`** in its config (deprecated), which the LinkMesh chart's
  entrypoint still writes; the lab entrypoint leaves it out.
- **sFlow:** SR Linux sends sFlow v5, but the virtual SR Linux sends **counter
  samples only, no flow samples**. LinkMesh 1.501.1 also **refuses a `netflow`
  receiver** (supported: filelog, fluentforward, hostmetrics, http_check, journald,
  k8s_*, kubeletstats, otlp, prometheus, statsd, syslog, tcp_check, tcplog, udplog,
  windowseventlog). So sFlow is configured and on the wire, but not collected.
- **LinkMesh Community licence** (lab default): up to 5 collectors; the explicit
  config-as-code re-push needs Enterprise, but every save in the API already pushes
  the config over OpAMP, so the lab does not need it.
- **MTU drops are not counted** as interface discards by the virtual SR Linux; the
  MTU fault is visible as a throughput collapse and in the TCP test (MSS effect).
- **"Site link" failure** is simulated with iptables in collector-b's namespace
  (all traffic to/from LinkMesh, Prometheus and Loki dropped): the management
  network is one Docker bridge, so there is no separate NOC uplink to cut.
- **Probes** run in client containers of the leafs (a-c1, b-c1), so they measure
  host-to-host across leafs, DCI and IPsec, not leaf-to-leaf loopbacks.
- The Mac is busy at this size: SR Linux logs CPU > 80 % and memory > 70 %
  warnings (visible in the syslog panel), and probe RTTs show spikes.
