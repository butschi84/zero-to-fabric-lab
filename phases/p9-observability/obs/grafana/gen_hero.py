#!/usr/bin/env python3
"""Hero dashboard "Fabric live" (dashboards/fabric-live.json): one picture for video
and blog. Top: the topology of both sites as a Grafana canvas, nodes coloured by
their BGP state, links coloured by link state (a failed link turns red). Below:
one row per layer with few, large numbers. Colours = the series' video kit
tokens (opensight-video netkit/tokens.ts) and the tenant scheme "colour".
Fault scenarios (faults.sh) add annotations tagged "fault"."""
import json, pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from tokens import *              # brand + video-kit tokens; failures are magenta, never red
BAD = FAIL
P = "srl_"
BGP, BFD, IFOPER = P + "network_instance_protocols_bgp_neighbor_session_state", P + "bfd_network_instance_peer_session_state", P + "interface_oper_state"
RIB = P + "network_instance_bgp_rib_afi_safi_evpn_rib_in_out_rib_in_post_{}_route_used_route"
PROM, LOKI = {"type": "prometheus", "uid": "prom"}, {"type": "loki", "uid": "loki"}

# ------------------------------------------------------------------ topology canvas
W, H = 1880, 360
NODES = {  # name: (x, y) centre in canvas pixels
    "leaf-a1": (230, 300), "spine-a": (230, 175), "gw-a": (520, 95), "gw-a2": (520, 255),
    "leaf-b1": (1650, 300), "spine-b": (1650, 175), "gw-b": (1360, 95), "gw-b2": (1360, 255),
    "WAN": (940, 175), "br1": (940, 305),
}
# links: (from, to, query giving 1 = up / 0 = down)
up = lambda n, i: f'{IFOPER}{{source="{n}",interface_name="ethernet-1/{i}"}}'
LINKS = [("spine-a", "leaf-a1", up("spine-a", 1)), ("spine-a", "gw-a", up("spine-a", 7)), ("spine-a", "gw-a2", up("spine-a", 8)),
         ("spine-b", "leaf-b1", up("spine-b", 1)), ("spine-b", "gw-b", up("spine-b", 7)), ("spine-b", "gw-b2", up("spine-b", 8)),
         ("gw-a", "WAN", up("gw-a", 1)), ("gw-a2", "WAN", up("gw-a2", 1)), ("gw-b", "WAN", up("gw-b", 1)), ("gw-b2", "WAN", up("gw-b2", 1)),
         ("br1", "WAN", 'min(ipsec_child_sa_installed{gateway="ipsec-br"})')]
targets, overrides = [], []
def tgt(expr, name):
    targets.append({"refId": f"Q{len(targets)}", "expr": expr, "legendFormat": name, "datasource": PROM, "instant": True})
for n in NODES:
    if n in ("WAN",):
        continue
    # no value when the node's newest sample is older than 20 s (site cut): the tile falls back to WARN
    tgt(f'(sum({BGP}{{source="{n}"}}) / count({BGP}{{source="{n}"}})) and on() (time() - max(timestamp({BGP}{{source="{n}"}})) < 20)', n)
def fresh(q):  # links of a node whose telemetry is stale fall back to slate 600 (dim)
    srcs = [x for x in NODES if f'"{x}"' in q]
    return q if not srcs else f'({q}) and on() (time() - max(timestamp({BGP}{{source="{srcs[0]}"}})) < 20)'
for a, b, q in LINKS:
    tgt(fresh(q), f"{a}~{b}")
th = thr((None, FAIL), (0.5, WARN), (0.999, OK))

def node(name):
    x, y = NODES[name]; w, h = (150, 64) if name != "WAN" else (190, 80)
    el = {"type": "metric-value" if name != "WAN" else "text", "name": name, "constraint": {"horizontal": "left", "vertical": "top"},
          "placement": {"left": x - w / 2, "top": y - h / 2, "width": w, "height": h},
          "config": {"text": {"fixed": name if name == "WAN" else "", "field": name if name != "WAN" else None, "mode": "fixed" if name == "WAN" else "field"},
                     "color": {"fixed": INK9}, "size": 20, "align": "center", "valign": "middle"},
          "background": {"color": {"fixed": SL2} if name == "WAN" else {"field": name, "fixed": WARN}},
          "border": {"color": {"fixed": SL4}, "width": 1, "radius": 10}, "connections": []}
    if name != "WAN":   # show the name, the value only colours the tile
        el["config"]["text"] = {"fixed": name, "mode": "fixed"}
        el["config"]["color"] = {"fixed": INK9}
    return el
els = {n: node(n) for n in NODES}
def anchor(a, b):
    (ax, ay), (bx, by) = NODES[a], NODES[b]
    dx, dy = bx - ax, by - ay
    if abs(dx) > abs(dy) * 1.2:
        return {"x": 1 if dx > 0 else -1, "y": 0}, {"x": -1 if dx > 0 else 1, "y": 0}
    return {"x": 0, "y": -1 if dy > 0 else 1}, {"x": 0, "y": 1 if dy > 0 else -1}   # canvas y: +1 = top
for a, b, _ in LINKS:
    sa, tb = anchor(a, b)
    els[a]["connections"].append({"targetName": b, "source": sa, "target": tb, "path": "straight",
                                  "direction": {"fixed": "none", "mode": "fixed"},
                                  "color": {"field": f"{a}~{b}", "fixed": SL6}, "size": {"fixed": 2.5, "min": 2, "max": 3}})
labels = [("SITE A", 230, 30), ("SITE B", 1650, 30), ("BRANCH (IPsec)", 1150, 305), ("DCI / WAN", 940, 110)]
for t, x, y in labels:
    els[t] = {"type": "text", "name": t, "constraint": {"horizontal": "left", "vertical": "top"},
              "placement": {"left": x - 150, "top": y - 18, "width": 300, "height": 36},
              "config": {"text": {"fixed": t, "mode": "fixed"}, "color": {"fixed": MAG2 if t.startswith("SITE") else SL2}, "size": 20, "align": "center", "valign": "middle"},
              "background": {"color": {"fixed": "transparent"}}, "border": {"color": {"fixed": "transparent"}}, "connections": []}
canvas = {"type": "canvas", "title": "Fabric live: nodes by BGP sessions up (pink: degraded or no telemetry), links by link state (magenta: down, dim: no telemetry)", "datasource": PROM,
          "gridPos": {"x": 0, "y": 0, "w": 24, "h": 11}, "targets": targets,
          "fieldConfig": {"defaults": {"min": 0, "max": 1, "color": {"mode": "thresholds"}, "thresholds": th}, "overrides": []},
          "options": {"inlineEditing": False, "showAdvancedTypes": True, "panZoom": False,
                      "root": {"type": "frame", "name": "root", "elements": list(els.values()),
                               "background": {"color": {"fixed": INK}}, "border": {"color": {"fixed": "transparent"}},
                               "constraint": {"horizontal": "left", "vertical": "top"}, "placement": {"left": 0, "top": 0, "width": W, "height": H}}}}

# ------------------------------------------------------------------ rows
panels, pid, y = [canvas], [1], [11]
def nid(): pid[0] += 1; return pid[0]
def row(t):
    pass   # no row headers: every panel title starts with its layer, so the hero fits one 1080p screen
def stat(title, tg, x, w, h=6, unit=None, thr=None, decimals=0, ds=PROM, text="value_and_name", colormode="background_solid", minv=None, maxv=None):
    panels.append({"type": "stat", "title": title, "id": nid(), "datasource": ds, "gridPos": {"x": x, "y": y[0], "w": w, "h": h},
        "targets": [{"refId": chr(65 + i), "expr": e, "legendFormat": l, "instant": True, "datasource": ds} for i, (e, l) in enumerate(tg)],
        "options": {"colorMode": colormode, "graphMode": "none", "textMode": text, "justifyMode": "center", "reduceOptions": {"calcs": ["lastNotNull"]},
                    "text": {"titleSize": 22, "valueSize": 54}},
        "fieldConfig": {"defaults": {**({"unit": unit} if unit else {}), "decimals": decimals, **({"min": minv} if minv is not None else {}), **({"max": maxv} if maxv is not None else {}),
                        "color": {"mode": "thresholds"}, "thresholds": thr or thr((None, SL2))}, "overrides": []}})
def ts(title, tg, x, w, h=8, unit=None, stack=None, overrides=None, minv=None, maxv=None):
    panels.append({"type": "timeseries", "title": title, "id": nid(), "datasource": PROM, "gridPos": {"x": x, "y": y[0], "w": w, "h": h},
        "targets": [{"refId": chr(65 + i), "expr": e, "legendFormat": l, "datasource": PROM} for i, (e, l) in enumerate(tg)],
        "options": {"legend": {"displayMode": "list", "placement": "bottom", "fontSize": 16}, "tooltip": {"mode": "multi"}},
        "fieldConfig": {"defaults": {**({"unit": unit} if unit else {}), **({"min": minv} if minv is not None else {}), **({"max": maxv} if maxv is not None else {}),
                        "custom": {"lineWidth": 3, "fillOpacity": 35 if stack else 10, "gradientMode": "opacity", **({"stacking": {"mode": stack, "group": "A"}} if stack else {})},
                        "color": {"mode": "shades", "fixedColor": SL2}}, "overrides": overrides or []}})
fix = lambda name, col: {"matcher": {"id": "byName", "options": name}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": col}}]}
G100 = thr((None, FAIL), (0.9, WARN), (0.999, OK))

H4 = 4
row("Underlay")
stat("UNDERLAY · BGP up", [(f"sum({BGP}) / count({BGP})", "BGP")], 0, 4, H4, "percentunit", G100, text="value", minv=0, maxv=1)
stat("UNDERLAY · BFD up", [(f"sum({BFD}) / count({BFD})", "BFD")], 4, 4, H4, "percentunit", G100, text="value", minv=0, maxv=1)
ts("UNDERLAY · ECMP: spine-a towards gw-a / gw-a2 (share of traffic)", [(f'rate({P}interface_statistics_out_octets_total{{source="spine-a",interface_name="ethernet-1/7"}}[30s])*8', "via gw-a"),
   (f'rate({P}interface_statistics_out_octets_total{{source="spine-a",interface_name="ethernet-1/8"}}[30s])*8', "via gw-a2")], 8, 16, H4, "percentunit", stack="percent",
   overrides=[fix("via gw-a", SL2), fix("via gw-a2", MAG2)])
panels[-1]["fieldConfig"]["defaults"]["custom"].update({"drawStyle": "line", "fillOpacity": 70, "lineWidth": 1, "lineInterpolation": "smooth"})
panels[-1]["interval"] = "30s"
y[0] += H4
stat("OVERLAY · EVPN routes in use", [(f'sum({RIB.format("mac_ip")})', "Type 2"), (f'sum({RIB.format("imet")})', "Type 3"), (f'sum({RIB.format("ip_prefix")})', "Type 5")], 0, 10, H4,
     thr=thr((None, SL2)), colormode="value")
stat("OVERLAY · VTEPs reachable", [(f'sum(count by (source) ({P}tunnel_vxlan_tunnel_vtep_index{{source=~"leaf-.*"}}))', "VTEPs")], 10, 4, H4,
     thr=thr((None, SL2)), colormode="value", text="value")
stat("OVERLAY · MAC mobility", [(f'sum({P}network_instance_bridge_table_statistics_mac_type_active_entries{{mac_type_type="duplicate"}}) or vector(0)', "duplicate MACs now"),
     ('sum(count_over_time({service_name="unknown_service"} |~ "(?i)duplicate mac" [10m]))', "events 10 min")], 14, 10, H4,
     thr=thr((None, OK), (1, FAIL)))
panels[-1]["targets"][1]["datasource"] = LOKI
panels[-1]["datasource"] = {"type": "datasource", "uid": "-- Mixed --"}   # Prometheus + Loki in one panel
panels[-1]["fieldConfig"]["defaults"]["noValue"] = "0"
panels[-1]["fieldConfig"]["overrides"] = [{"matcher": {"id": "byFrameRefID", "options": "B"}, "properties": [{"id": "displayName", "value": "MAC moves in syslog, 10 min"}]}]
y[0] += H4
VRF = f'{P}network_instance_route_table_ipv4_unicast_statistics_active_routes'
stat("TENANTS · routes per VRF (leafs, both sites)", [(f'sum by (network_instance_name) ({VRF}{{source=~"leaf-.*",network_instance_name!~"default|mgmt"}})', "{{network_instance_name}}")], 0, 24, H4,
     thr=thr((None, SL2)), colormode="value")   # tenant colour on the number: Grafana picks white text on a blue tile (2.3:1)
panels[-1]["fieldConfig"]["overrides"] = [fix(n, c) for n, c in TENANT.items()]
y[0] += H4
stat("DCI · latency A <-> B", [('avg((rate(smokeping_response_duration_seconds_sum{instance="172.30.30.101:9374",host=~"10.1.1.21|10.1.3.21"}[1m]) / rate(smokeping_response_duration_seconds_count{instance="172.30.30.101:9374",host=~"10.1.1.21|10.1.3.21"}[1m])) >= 0)', "RTT")], 0, 5, H4, "s", decimals=1,
     thr=thr((None, OK), (0.025, WARN), (0.06, FAIL)), text="value")
stat("DCI · jitter (p90 - p10)", [('histogram_quantile(0.9, sum by (le) (rate(smokeping_response_duration_seconds_bucket{instance="172.30.30.101:9374",host=~"10.1.1.21|10.1.3.21"}[1m]))) - histogram_quantile(0.1, sum by (le) (rate(smokeping_response_duration_seconds_bucket{instance="172.30.30.101:9374",host=~"10.1.1.21|10.1.3.21"}[1m])))', "jitter")], 5, 5, H4, "s", decimals=1,
     thr=thr((None, OK), (0.03, WARN), (0.06, FAIL)), text="value")
stat("DCI · IPsec tunnels up", [('sum(ipsec_child_sa_installed)', "child SAs")], 10, 4, H4,
     thr=thr((None, FAIL), (1, OK)), text="value")
ts("DCI · RTT site A -> site B", [('rate(smokeping_response_duration_seconds_sum{instance="172.30.30.101:9374",host=~"10.1.1.21|10.1.3.21"}[1m]) / rate(smokeping_response_duration_seconds_count{instance="172.30.30.101:9374",host=~"10.1.1.21|10.1.3.21"}[1m])', "to {{host}}")], 14, 10, H4, "s",
   overrides=[fix("to 10.1.1.21", SL2), fix("to 10.1.3.21", MAG2)])
y[0] += H4

for pn in panels:   # probes lost (MAC or site fault): say so instead of an empty tile
    if pn.get("title", "").startswith(("DCI · latency", "DCI · jitter")):
        pn["fieldConfig"]["defaults"]["noValue"] = "no reply"
dash = {"uid": "ztf-fabric-live", "title": "Zero to Fabric · Fabric live", "tags": ["zero-to-fabric", "phase9", "hero"], "timezone": "utc",
        "schemaVersion": 41, "version": 1, "refresh": "5s", "time": {"from": "now-10m", "to": "now"}, "style": "dark", "graphTooltip": 1,
        "annotations": {"list": [{"builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": True, "hide": True, "iconColor": "rgba(0, 211, 255, 1)", "name": "Annotations & Alerts", "type": "dashboard"},
                                 {"datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": True, "iconColor": MAG, "name": "Faults",
                                  "target": {"type": "tags", "tags": ["fault"], "limit": 100, "matchAny": True}}]},
        "panels": panels}
for i, p in enumerate(panels):
    p.setdefault("id", 100 + i)
pathlib.Path(__file__).with_name("dashboards").joinpath("fabric-live.json").write_text(json.dumps(dash, indent=1))
print(len(panels), "panels")
