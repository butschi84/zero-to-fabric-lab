#!/usr/bin/env python3
"""Measured WCAG contrast of every text/background pair the phase 9 dashboards use."""
import pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from tokens import *
pairs = [  # (text, background, where)
    (INK9, OK, "node tile / stat tile OK (ink on slate 200)"), (INK9, WARN, "stat tile WARN (ink on magenta 200)"),
    (INK9, FAIL, "node tile / stat tile FAIL (ink on magenta 500)"), (INK9, SL2, "WAN tile (ink on slate 200)"),
    *[(c, GRAFANA_PANEL_BG, f"tenant number {n} (tenant colour on Grafana panel)") for n, c in TENANT.items()],
    (WHITE, FAIL, "FAIL tile if Grafana picks white text (large numbers only: AA-large)"),
    (SL2, GRAFANA_PANEL_BG, "value text slate 200 on Grafana panel"), (MAG, GRAFANA_PANEL_BG, "value text magenta 500 on Grafana panel"),
    (MAG2, INK, "site labels magenta 200 on ink canvas"), (SL2, INK, "labels slate 200 on ink canvas"), (WHITE, GRAFANA_PANEL_BG, "panel titles white on Grafana panel"),
]
out = ["method: WCAG 2.x relative luminance, ratio (L1 + 0.05) / (L2 + 0.05); AA = 4.5 normal text, 3.0 large text", ""]
for fg, bg, where in pairs:
    r = contrast(fg, bg)
    out.append(f"{r:5.2f}  {'AA' if r >= 4.5 else 'AA-large' if r >= 3 else 'FAIL'}  {fg} on {bg}  {where}")
print("\n".join(out))
