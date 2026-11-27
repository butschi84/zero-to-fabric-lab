#!/usr/bin/env python3
"""Configure the two site collectors through LinkMesh (the only place their
config is written). Idempotent enough for a lab: it creates what is missing.

Per collector (scope = that collector):
  sources:      OTLP gRPC :4317 (gnmic), Syslog UDP :5514 RFC 5424 (SR Linux),
                Prometheus scrape (active probes, IPsec exporters)
  (sFlow: LinkMesh 1.501.1 refuses a netflow receiver source, see README)
  destinations: Prometheus via OTLP/HTTP (metrics), Loki via OTLP/HTTP (logs),
                both with LinkMesh's durable (disk) queue, so a cut-off collector buffers
  route:        everything -> both destinations
then publishes and writes the resulting entities to evidence/p9-observability/linkmesh/.
"""
import json, os, pathlib, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from lm import call

OUT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
OUT.mkdir(parents=True, exist_ok=True)
SITES = {"a": {"host": "collector-a", "scrape": ["172.30.30.101:9374", "172.30.30.43:9101", "172.30.30.45:9101"]},
         "b": {"host": "collector-b", "scrape": ["172.30.30.103:9374", "172.30.30.44:9101"]}}

def by_name(path, name):
    return next((x for x in call("GET", path) if x.get("name") == name), None)

def ensure(path, body):
    return by_name(path, body["name"]) or call("POST", path, body)

# collectors registered by host.name
cols = {}
for _ in range(90):
    for c in call("GET", "/api/v1/collectors"):
        for s, d in SITES.items():
            if d["host"] in json.dumps(c):
                cols[s] = c
    if len(cols) == 2: break
    time.sleep(2)
if len(cols) != 2: raise SystemExit(f"collectors not registered: {list(cols)}")

# sources are created from LinkMesh's templates (a template cannot be activated directly)
otlp = ensure("/api/v1/sources", {"name": "gNMI telemetry (OTLP from gnmic)", "receiverType": "otlp", "signalTypes": ["metrics"],
              "platform": "all", "defaultConfig": {"grpc_endpoint": "0.0.0.0:4317"}})
syslog = ensure("/api/v1/sources", {"name": "SR Linux syslog (UDP 5514, RFC 5424)", "receiverType": "syslog", "signalTypes": ["logs"],
                "platform": "all", "defaultConfig": {"listen_address": "0.0.0.0:5514", "protocol": "udp", "rfc": "rfc5424"}})
scrape = {s: ensure("/api/v1/sources", {"name": f"Probes and IPsec site {s.upper()} (Prometheus scrape)", "receiverType": "prometheus",
          "signalTypes": ["metrics"], "platform": "all",
          "defaultConfig": {"targets": d["scrape"], "scrape_interval": "10s", "metrics_path": "/metrics", "scheme": "http"}}) for s, d in SITES.items()}
prom = ensure("/api/v1/destinations", {"name": "Prometheus (OTLP)", "exporterType": "otlphttp", "signalTypes": ["metrics"], "platform": "all",
              "defaultConfig": {"endpoint": "http://172.30.30.210:9090/api/v1/otlp", "compression": "gzip", "durable_queue": True, "timeout": "10s"}})
loki = ensure("/api/v1/destinations", {"name": "Loki (OTLP)", "exporterType": "otlphttp", "signalTypes": ["logs"], "platform": "all",
              "defaultConfig": {"endpoint": "http://172.30.30.212:3100/otlp", "compression": "gzip", "durable_queue": True, "timeout": "10s"}})

result = {}
for s, c in sorted(cols.items()):
    cid = c["collectorId"]
    have = {a.get("sourceId") or (a.get("source") or {}).get("_id") for a in call("GET", f"/api/v1/collectors/{cid}/sources")}
    acts = [(otlp, {}), (syslog, {}), (scrape[s], {})]
    for so, ov in acts:
        if so["_id"] not in have:
            call("POST", f"/api/v1/collectors/{cid}/sources", {"sourceId": so["_id"], "configOverrides": ov})
    dacts = {a.get("destinationId") or (a.get("destination") or {}).get("_id"): a["_id"] for a in call("GET", f"/api/v1/collectors/{cid}/destinations")}
    for d in (prom, loki):
        if d["_id"] not in dacts:
            dacts[d["_id"]] = call("POST", f"/api/v1/collectors/{cid}/destinations", {"destinationId": d["_id"], "configOverrides": {}})["_id"]
    rname = f"site-{s}: all signals to Prometheus and Loki"
    if not by_name(f"/api/v1/collectors/{cid}/routes", rname):
        call("POST", "/api/v1/routes", {"name": rname, "scope": {"kind": "collector", "id": cid},
             "destinationIds": [dacts[prom["_id"]], dacts[loki["_id"]]], "inputFilter": "true", "isFinal": True, "enabled": True, "priority": 100})
    # every save above already pushed the rendered config over OpAMP (the explicit
    # config-as-code re-push needs an Enterprise licence; the lab runs Community)
    result[s] = {"collectorId": cid}
    print(f"site {s}: collector {cid} configured")

ours = {otlp["_id"], syslog["_id"], prom["_id"], loki["_id"], *(x["_id"] for x in scrape.values())}
for name, path in [("collectors", "/api/v1/collectors"), ("sources", "/api/v1/sources"), ("destinations", "/api/v1/destinations")]:
    rows = call("GET", path)
    if name != "collectors":   # only the lab's own entities, not LinkMesh's built-in catalog
        rows = [{k: v for k, v in r.items() if k != "configSchema"} for r in rows if r["_id"] in ours]
    (OUT / f"{name}.json").write_text(json.dumps(rows, indent=1))
for s, c in sorted(cols.items()):
    (OUT / f"routes-site-{s}.json").write_text(json.dumps(call("GET", f"/api/v1/collectors/{c['collectorId']}/routes"), indent=1))
(OUT / "bootstrap-result.json").write_text(json.dumps(result, indent=1))
