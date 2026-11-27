#!/usr/bin/env python3
"""Compact DHCP exchange from tshark fields (ip.src|ip.dst|dhcp.option.dhcp|
dhcp.hw.mac_addr|dhcp.ip.relay|dhcp.ip.your|option82 circuit-id hex|remote-id).
Prints one line per packet and the option-82 suboptions of each DISCOVER."""
import sys

T = {"1": "DISCOVER", "2": "OFFER", "3": "REQUEST", "5": "ACK"}
for ln in sys.stdin:
    f = ln.rstrip("\n").split("|")
    if len(f) < 8:
        continue
    print(f"{f[0]:12} -> {f[1]:12} {T.get(f[2], f[2]):9} giaddr={f[4]:12} yiaddr={f[5]:11} mac={f[3].split(",")[0]}")
    if f[2] == "1" and f[6]:
        cid = bytes.fromhex(f[6]).decode(errors="replace")
        print(f"{'':16}option 82: circuit-id=\"{cid}\" remote-id={f[7]}")
