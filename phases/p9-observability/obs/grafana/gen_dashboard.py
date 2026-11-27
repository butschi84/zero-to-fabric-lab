#!/usr/bin/env python3
"""Generate the provisioned Grafana dashboard (dashboards/fabric.json) for phase 9:
fabric overview, underlay, overlay, tenants, sites/WAN and the syslog stream.
Metric names are what Prometheus makes of gnmic's OTLP output (prefix srl_)."""
import json, pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).parent))
from tokens import *   # brand + video-kit colours, failures magenta (never red)

P = "srl_"
BGP = P + "network_instance_protocols_bgp_neighbor_session_state"
BFD = P + "bfd_network_instance_peer_session_state"
IFUP = P + "interface_oper_state"
RIB = P + "network_instance_bgp_rib_afi_safi_evpn_rib_in_out_rib_in_post_{}_route_used_route"
SITE = '{site=~"$site"}'
panels, y = [], 0
pid = 0

def nid():
    global pid; pid += 1; return pid

def row(title):
    global y
    panels.append({"type": "row", "title": title, "id": nid(), "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "collapsed": False}); y += 1

def panel(kind, title, targets, x, w, h, unit=None, extra=None, ds="prom"):
    p = {"type": kind, "title": title, "id": nid(), "datasource": {"type": "prometheus" if ds == "prom" else "loki", "uid": ds},
         "gridPos": {"x": x, "y": y, "w": w, "h": h},
         "targets": [{"refId": chr(65 + i), "expr": e, "legendFormat": l, **({"instant": True} if kind == "stat" else {})} for i, (e, l) in enumerate(targets)],
         "fieldConfig": {"defaults": {**({"unit": unit} if unit else {}), "color": {"mode": "shades", "fixedColor": SL2}}, "overrides": []}, "options": {}}
    if extra: p.update(extra)
    panels.append(p)

def nextline(h):
    global y; y += h

stat_opts = {"options": {"colorMode": "background", "graphMode": "none", "textMode": "value_and_name", "reduceOptions": {"calcs": ["lastNotNull"]}},
             "fieldConfig": {"defaults": {"unit": "percentunit", "min": 0, "max": 1, "decimals": 0,
                             "color": {"mode": "thresholds"}, "thresholds": thr((None, FAIL), (0.95, WARN), (1, OK))}, "overrides": []}}
state_opts = {"fieldConfig": {"defaults": {"min": 0, "max": 1, "custom": {"lineInterpolation": "stepAfter", "fillOpacity": 10},
              "mappings": [{"type": "value", "options": {"0": {"text": "down", "color": FAIL}, "1": {"text": "up", "color": OK}}}]}, "overrides": []}}

row("Fabric overview")
panel("stat", "BGP sessions established", [(f"sum({BGP}{SITE}) / count({BGP}{SITE})", "BGP")], 0, 6, 4, extra=stat_opts)
panel("stat", "BFD sessions up", [(f"sum({BFD}{SITE}) / count({BFD}{SITE})", "BFD")], 6, 6, 4, extra=stat_opts)
ADM = P + "interface_admin_state"
panel("stat", "Fabric ports up (of the enabled ones)", [(f'sum({IFUP}{{site=~"$site"}} and on(source, interface_name) {ADM} == 1) / count({ADM}{{site=~"$site"}} == 1)', "ports")], 12, 6, 4, extra=stat_opts)
panel("stat", "Duplicate MACs (MAC flapping)", [(f'sum({P}network_instance_bridge_table_statistics_mac_type_active_entries{{mac_type_type="duplicate",site=~"$site"}}) or vector(0)', "duplicate MACs")], 18, 6, 4,
      extra={"options": {"colorMode": "background", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"]}},
             "fieldConfig": {"defaults": {"color": {"mode": "thresholds"}, "thresholds": thr((None, OK), (1, FAIL))}, "overrides": []}})
nextline(4)

row("Underlay: links, ECMP, BGP, BFD")
panel("timeseries", "Link utilisation (out)", [(f"rate({P}interface_statistics_out_octets_total{SITE}[30s]) * 8", "{{source}} {{interface_name}}")], 0, 12, 8, "bps")
panel("timeseries", "ECMP: spine-a towards the two gateways (out)", [(f'rate({P}interface_statistics_out_octets_total{{source="spine-a",interface_name=~"ethernet-1/(7|8)"}}[30s]) * 8', "spine-a {{interface_name}}")], 12, 12, 8, "bps")
nextline(8)
panel("timeseries", "Errors and drops per second", [(f"rate({P}interface_statistics_in_discarded_packets_total{SITE}[30s]) + rate({P}interface_statistics_out_discarded_packets_total{SITE}[30s])", "discards {{source}} {{interface_name}}"),
      (f"rate({P}interface_statistics_in_error_packets_total{SITE}[30s]) + rate({P}interface_statistics_out_error_packets_total{SITE}[30s])", "errors {{source}} {{interface_name}}")], 0, 8, 8, "pps")
panel("timeseries", "BGP sessions established per node", [(f"sum by (source) ({BGP}{SITE})", "{{source}}")], 8, 8, 8, extra={"fieldConfig": {"defaults": {"custom": {"lineInterpolation": "stepAfter"}, "decimals": 0}, "overrides": []}})
panel("timeseries", "BFD sessions up per node", [(f"sum by (source) ({BFD}{SITE})", "{{source}}")], 16, 8, 8, extra={"fieldConfig": {"defaults": {"custom": {"lineInterpolation": "stepAfter"}, "decimals": 0}, "overrides": []}})
nextline(8)

row("Overlay: EVPN, VTEPs, MAC tables")
panel("timeseries", "EVPN routes in use per type", [(f'sum by (source) ({RIB.format(t)}{SITE})', f"{n} {{{{source}}}}") for t, n in (("mac_ip", "Type 2"), ("imet", "Type 3"), ("ip_prefix", "Type 5"))], 0, 8, 8)
panel("timeseries", "Remote VTEPs per node", [(f"count by (source) ({P}tunnel_vxlan_tunnel_vtep_index{SITE})", "{{source}}")], 8, 8, 8)
panel("timeseries", "MAC table size (active entries)", [(f'{P}network_instance_bridge_table_statistics_active_entries{SITE}', "{{source}} {{network_instance_name}}")], 16, 8, 8)
nextline(8)
panel("logs", "MAC moves and duplicates (syslog)", [('{service_name="unknown_service"} |~ "(?i)(duplicate mac|mac.*mov|flap)"', "")], 0, 24, 6, ds="loki")
nextline(6)

row("Tenants (VRFs)")
panel("timeseries", "IPv4 routes per VRF", [(f'{P}network_instance_route_table_ipv4_unicast_statistics_active_routes{{network_instance_name!~"default|mgmt",site=~"$site"}}', "{{network_instance_name}} @ {{source}}")], 0, 24, 7)
nextline(7)

row("Sites and WAN: probes, IPsec")
panel("timeseries", "Probe round-trip time (avg over 30 s)", [('rate(smokeping_response_duration_seconds_sum[30s]) / rate(smokeping_response_duration_seconds_count[30s])', "{{instance}} -> {{host}}")], 0, 8, 8, "s")
panel("timeseries", "Probe loss", [('clamp_min(1 - increase(smokeping_response_duration_seconds_count[1m]) / increase(smokeping_requests_total[1m]), 0)', "{{instance}} -> {{host}}")], 8, 8, 8, "percentunit")
panel("timeseries", "IPsec: ESP traffic per tunnel (child SAs installed in legend)", [('rate(ipsec_child_sa_bytes_total[30s]) * 8', "{{gateway}} {{tunnel}} {{direction}}")], 16, 8, 8, "bps")
nextline(8)

row("Syslog from the fabric")
panel("logs", "SR Linux syslog (via the site collectors)", [('{service_name="unknown_service"} != "TLS profile"', "")], 0, 24, 9, ds="loki")
nextline(9)

dash = {"uid": "ztf-fabric", "title": "Zero to Fabric · Fabric observability", "tags": ["zero-to-fabric", "phase9"], "timezone": "utc",
        "schemaVersion": 41, "version": 1, "refresh": "5s", "time": {"from": "now-15m", "to": "now"},
        "templating": {"list": [{"name": "site", "type": "custom", "query": "a,b", "current": {"text": "All", "value": "$__all"},
                                 "includeAll": True, "allValue": ".*", "multi": False, "label": "Site"}]},
        "panels": panels}
pathlib.Path(__file__).with_name("dashboards").joinpath("fabric.json").write_text(json.dumps(dash, indent=1))
print(len(panels), "panels")
