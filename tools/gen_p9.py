#!/usr/bin/env python3
"""Phase 9 configs = phase 8 configs + observability.

Copies phases/p8-multisite/configs (SR Linux, FRR, IPsec) to
phases/p9-observability/configs and appends to every SR Linux node:
- syslog to its SITE collector over the out-of-band management network
  (network-instance mgmt), RFC 5424 over UDP 5514;
- sFlow v5 (1:1000) on all fabric / WAN ports to the same collector, UDP 6343;
- WAN (ethernet-1/1 on the gateways) at IP MTU 9000 as the healthy baseline;
- the EDA discovery gRPC server switched off (it only logs "Unable to retrieve TLS
  profile 'EDA'" every second on a lab without EDA).
gNMI needs nothing: containerlab enables the gNMI server on 57400 (mgmt).
"""
import pathlib, re, shutil

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC, DST = ROOT / "phases/p8-multisite/configs", ROOT / "phases/p9-observability/configs"
COLLECTOR = {"a": "172.30.30.201", "b": "172.30.30.202"}
# site of each SR Linux node; the branch reports to site A (its primary hub)
SITE = {"spine-a": "a", "leaf-a1": "a", "gw-a": "a", "gw-a2": "a", "br1": "a",
        "spine-b": "b", "leaf-b1": "b", "gw-b": "b", "gw-b2": "b"}
MGMT = {"spine-a": 11, "spine-b": 12, "leaf-a1": 21, "leaf-b1": 22, "br1": 25,
        "gw-a": 31, "gw-b": 32, "gw-a2": 33, "gw-b2": 34}

if DST.exists():
    shutil.rmtree(DST)
shutil.copytree(SRC, DST)
for node, site in SITE.items():
    f = DST / f"{node}.cli"
    cfg = f.read_text()
    # healthy baseline: jumbo IP MTU on the WAN (phase 8 ends at 1500 after its MTU test);
    # the MTU fault in faults.sh lowers it back to 1500
    cfg = cfg.replace("set / interface ethernet-1/1 subinterface 0 ip-mtu 1500", "set / interface ethernet-1/1 subinterface 0 ip-mtu 9000")
    ports = sorted(set(re.findall(r"set / interface (ethernet-1/\d+) admin-state enable", cfg)))
    c = COLLECTOR[site]
    lines = [
             "set / system grpc-server eda-discovery admin-state disable",
             "set / system logging network-instance mgmt",
             f"set / system logging remote-server {c} transport udp",
             f"set / system logging remote-server {c} remote-port 5514",
             f"set / system logging remote-server {c} facility local6 priority match-above informational",
             "set / system sflow admin-state enable",
             "set / system sflow sample-rate 1000",
             f"set / system sflow collector 1 collector-address {c}",
             "set / system sflow collector 1 network-instance mgmt",
             f"set / system sflow collector 1 source-address 172.30.30.{MGMT[node]}",
             "set / system sflow collector 1 port 6343"]
    lines += [f"set / interface {p} sflow admin-state enable" for p in ports]
    f.write_text(cfg.rstrip("\n") + "\n" + "\n".join(lines) + "\n")
print(f"p9: {len(SITE)} SR Linux configs with observability")
