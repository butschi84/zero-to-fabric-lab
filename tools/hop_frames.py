#!/usr/bin/env python3
"""Format tshark field output (P0-08) as a readable per-frame table with named MAC addresses.
stdin: tshark -T fields -E separator='|' -e frame.time_relative -e eth.src -e eth.dst -e _ws.col.Protocol
       -e ip.src -e ip.dst -e ip.ttl -e arp.opcode -e arp.src.proto_ipv4 -e arp.dst.proto_ipv4 -e icmp.type
usage: hop_frames.py <legend: "name mac" per line> [--request-only --point <name>]"""
import sys

legend = {}
for line in open(sys.argv[1]):
    if line.strip():
        name, mac = line.split()
        legend[mac.lower()] = name
req_only = "--request-only" in sys.argv
point = sys.argv[sys.argv.index("--point") + 1] if "--point" in sys.argv else ""
name = lambda m: f"{m} ({legend[m]})" if m in legend else (f"{m} (broadcast)" if m == "ff:ff:ff:ff:ff:ff" else m)

rows = []
for line in sys.stdin:
    f = line.rstrip("\n").split("|")
    if len(f) < 11: continue
    t, esrc, edst, proto, isrc, idst, ttl, op, asrc, adst, itype = f
    if op == "1": what = f"ARP who has {adst}? tell {asrc}"
    elif op == "2": what = f"ARP reply: {asrc} is here"
    elif itype in ("8", "0"): what = f"ICMP echo {'request' if itype == '8' else 'reply  '} {isrc} > {idst} ttl {ttl}"
    else: what = proto
    rows.append((float(t), esrc.lower(), edst.lower(), what, itype))

if req_only:
    for t, s, d, what, itype in rows:
        if itype == "8":
            parts = point.split("-")  # P0-08b-leaf1-e1-49 -> "leaf1 e1-49"
            where = parts[2] + " " + "-".join(parts[3:])
            print(f"{where:<14} MAC {name(s)} -> {name(d)}")
            print(f"{'':<14} {what}")
            break
    sys.exit(0)
for t, s, d, what, _ in rows:
    print(f"{t:6.3f}  {s} > {d}  {what}")
print()
print("MAC names: " + ", ".join(f"{n} {m}" for m, n in legend.items() if m in {r[1] for r in rows} | {r[2] for r in rows}))
