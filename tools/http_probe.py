#!/usr/bin/env python3
"""HTTP probe for failover tests: one new TCP connection every INTERVAL seconds
for DURATION seconds, timeout TIMEOUT each. Runs inside a lab client.
usage: python3 - URL DURATION INTERVAL TIMEOUT EVENT_AT < http_probe.py
Prints a summary: answers per server before/after EVENT_AT, failed requests,
and the longest gap without a successful answer."""
import socket, sys, time, urllib.request

url, dur, ivl, tmo, ev = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
t0 = time.time(); log = []
while (now := time.time()) - t0 < dur:
    try:
        r = urllib.request.urlopen(url, timeout=tmo).read().decode().split()[0]
    except (OSError, socket.timeout):
        r = None
    log.append((now - t0, r))
    time.sleep(max(0.0, ivl - (time.time() - now)))
ok = [t for t, r in log if r]
fails = [t for t, r in log if not r]
gap, prev = 0.0, None
for t, r in log:
    if r:
        if prev is not None:
            gap = max(gap, t - prev)
        prev = t
def count(sel):
    c = {}
    for t, r in log:
        if r and sel(t):
            c[r] = c.get(r, 0) + 1
    return " ".join(f"{k}={v}" for k, v in sorted(c.items())) or "-"
print(f"requests={len(log)} ok={len(ok)} failed={len(fails)} largest_gap_s={gap:.2f} "
      f"first_fail_s={(fails[0] - ev) if fails else 0:.2f} last_fail_s={(fails[-1] - ev) if fails else 0:.2f}")
print(f"before event: {count(lambda t: t < ev)}")
print(f"after event:  {count(lambda t: t >= ev)}")
print(f"last 3 s:     {count(lambda t: t >= dur - 3)}")
