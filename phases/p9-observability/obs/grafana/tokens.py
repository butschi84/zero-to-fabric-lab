"""Colours for the phase 9 dashboards = the OpenSight brand tokens (opensight-brandkit
tokens/palette.json) and the Zero to Fabric video kit (_kit/README, TENANT_SCHEME
"colour"). Rules taken from the kit: failures are never red (red is not in the
brand) - a problem lights up in magenta; underlay is slate; text on light fills is ink.
contrast() measures WCAG 2.x ratios; check_contrast.py writes the measured table."""
INK, INK9, PANEL = "#151719", "#15171a", "#1d2023"
WHITE, MAG, MAG2, MAG7 = "#ffffff", "#ff1a75", "#ffc2da", "#d1005e"
SL2, SL4, SL5, SL6 = "#c9d3d8", "#8b979d", "#6f8089", "#5b6b73"
GRAFANA_PANEL_BG = "#181b1f"   # Grafana dark theme panel surface (not themable in OSS Grafana)
OK, WARN, FAIL = SL2, MAG2, MAG          # status: calm slate / magenta 200 / magenta 500
LINK_UP, LINK_DOWN = SL4, MAG            # topology links
TENANT = {"corp": "#4fb3ff", "guest": "#ffb347", "mgmt": "#7be0a6", "shared": "#c9a7ff"}

def thr(*steps):
    """thresholds: thr((None, FAIL), (0.9, WARN), (0.999, OK))"""
    return {"mode": "absolute", "steps": [{"color": c, "value": v} for v, c in steps]}

def _lum(h):
    c = [int(h[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    c = [x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]

def contrast(a, b):
    la, lb = sorted((_lum(a), _lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)
