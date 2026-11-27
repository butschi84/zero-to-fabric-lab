#!/usr/bin/env python3
"""Minimal LinkMesh REST client for the lab (stdlib only). Admin credentials are
lab-only values set in obs/up.sh; nothing here is a real secret.
External LinkMesh (LINKMESH_URL set in obs/up.sh): credentials come from the
environment only - LM_TOKEN (a bearer token) or LM_EMAIL + LM_PW - never from a file."""
import json, os, urllib.request

BASE = os.environ.get("LM_URL", "http://127.0.0.1:18080")
EMAIL, PW = os.environ.get("LM_EMAIL", "admin@lab.local"), os.environ.get("LM_PW", "ZeroToFabric-lab1")
_tok = os.environ.get("LM_TOKEN") or None

def call(method, path, body=None, auth=True):
    global _tok
    if auth and _tok is None:
        _tok = call("POST", "/api/v1/auth/login", {"email": EMAIL, "password": PW}, auth=False)["token"]
    req = urllib.request.Request(BASE + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", **({"Authorization": f"Bearer {_tok}"} if auth else {})})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            d = json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{method} {path}: HTTP {e.code} {e.read()[:400]!r}")
    return d.get("data", d) if isinstance(d, dict) else d
