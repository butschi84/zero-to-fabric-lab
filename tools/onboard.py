#!/usr/bin/env python3
"""Onboard a hosting customer on one leaf: print the SR Linux CLI for it.

The values come from the same plan as every startup config (gen_configs.py):
tenant number -> VLAN, L2VNI, L3VNI, RT, EVI, gateway. Nothing is typed by hand.
usage: onboard.py <tenant> <leaf> <port> [subnet-prefix]   e.g. cust-c leaf1 ethernet-1/5 10.0.0
"""
import pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import gen_configs as g

tenant, leaf, port = sys.argv[1:4]
subnet = sys.argv[4] if len(sys.argv) > 4 else None
vlan = g.vlan_of(tenant, 1)
net = (tenant, 1, [leaf]) + ((subnet,) if subnet else ())
ph = dict(nets=[net], ports={leaf: [(port, vlan, f"{tenant} vm")]})
L = []
g.tenant_fabric(L, leaf, ph)
print("\n".join(L))
