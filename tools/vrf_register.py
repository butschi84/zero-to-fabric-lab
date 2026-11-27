#!/usr/bin/env python3
"""Tenant register (VRF/VNI/EVI/RD/RT) read from SR Linux state, not from the plan.

usage: vrf_register.py <node> <bgpvpn.json> <evpn.json> <tunnel.json> <type.json>
       (the JSON files are `info from state ... | as json` outputs, see lib.sh vrf_register)
Prints one line per MAC-VRF / IP-VRF: name, type, VNI, EVI, RD, export RT, import RT.
"""
import json, sys

node, fvpn, fevpn, ftun, ftype = sys.argv[1:6]
ld = lambda f: json.load(open(f))
types = {n["name"]: n.get("type", "").split(":")[-1] for n in ld(ftype).get("network-instance", [])}
vni = {v["index"]: v.get("ingress", {}).get("vni") for t in ld(ftun).get("tunnel-interface", []) for v in t.get("vxlan-interface", [])}
evpn = {}
for n in ld(fevpn).get("network-instance", []):
    for b in n.get("protocols", {}).get("bgp-evpn", {}).get("bgp-instance", []):
        idx = int(str(b.get("vxlan-interface", "vxlan1.0")).split(".")[-1])
        evpn[n["name"]] = (b.get("evi"), vni.get(idx))
rows = []
for n in ld(fvpn).get("network-instance", []):
    for b in n.get("protocols", {}).get("bgp-vpn", {}).get("bgp-instance", []):
        rt = b.get("route-target", {})
        evi, v = evpn.get(n["name"], (None, None))
        rows.append((n["name"], types.get(n["name"], "?"), v, evi, b.get("route-distinguisher", {}).get("rd"),
                     rt.get("export-rt", "").replace("target:", ""), rt.get("import-rt", "").replace("target:", "")))
rows.sort(key=lambda r: (r[1] != "ip-vrf", r[2] or 0))
print(f"{'node':7} {'network-instance':16} {'type':8} {'VNI':>6} {'EVI':>4}  {'RD':16} {'export RT':13} {'import RT':13}")
for r in rows:
    print(f"{node:7} {r[0]:16} {r[1]:8} {r[2]!s:>6} {r[3]!s:>4}  {r[4]!s:16} {r[5]:13} {r[6]:13}")
