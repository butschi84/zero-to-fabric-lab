#!/usr/bin/env python3
"""Tiny Prometheus exporter for strongSwan: reads `swanctl --list-sas --raw` on
every scrape and serves IKE / child SA state and ESP byte and packet counters on
:9101/metrics. Runs inside the IPsec containers (started by obs/up.sh)."""
import http.server, re, socket, subprocess

HOST = socket.gethostname()

def sas():
    raw = subprocess.run(["swanctl", "--list-sas", "--raw"], capture_output=True, text=True).stdout
    out = []
    for ev in raw.split("list-sa event {")[1:]:
        ike = ev.split(" ", 1)[0]
        head, _, children = ev.partition("child-sas {")
        st = re.search(r"\bstate=(\S+)", head); rh = re.search(r"remote-host=(\S+)", head)
        peer = rh.group(1) if rh else ""
        out.append(("ike", ike, st.group(1) if st else "", peer, {}))
        for c in re.finditer(r"(\S+) \{(name=[^{}]*)\}", children):
            kv = dict(re.findall(r"([\w-]+)=(\S+)", c.group(2)))
            out.append(("child", ike, kv.get("state", ""), peer, kv))
    return out

def render():
    L = ["# TYPE ipsec_ike_sa_established gauge", "# TYPE ipsec_child_sa_installed gauge",
         "# TYPE ipsec_child_sa_bytes_total counter", "# TYPE ipsec_child_sa_packets_total counter"]
    for kind, ike, state, peer, kv in sas():
        lab = f'gateway="{HOST}",tunnel="{ike}",peer="{peer}"'
        if kind == "ike":
            L.append(f"ipsec_ike_sa_established{{{lab}}} {1 if state == 'ESTABLISHED' else 0}")
        else:
            L.append(f"ipsec_child_sa_installed{{{lab}}} {1 if state == 'INSTALLED' else 0}")
            for d in ("in", "out"):
                L.append(f'ipsec_child_sa_bytes_total{{{lab},direction="{d}"}} {kv.get("bytes-" + d, 0)}')
                L.append(f'ipsec_child_sa_packets_total{{{lab},direction="{d}"}} {kv.get("packets-" + d, 0)}')
    return "\n".join(L) + "\n"

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = render().encode()
        self.send_response(200); self.send_header("Content-Type", "text/plain; version=0.0.4"); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass

http.server.ThreadingHTTPServer(("0.0.0.0", 9101), H).serve_forever()
