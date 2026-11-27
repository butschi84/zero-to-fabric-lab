#!/usr/bin/env bash
# One line per collector as LinkMesh sees it (status, version, last seen).
HERE="$(cd "$(dirname "$0")" && pwd)"
LM_URL=${LM_URL:-http://127.0.0.1:18080} python3 -c "
import sys; sys.path.insert(0, '$HERE'); from lm import call
for c in call('GET', '/api/v1/collectors'):
    print(f\"{c.get('name',''):<12} status={c.get('status','')} version={c.get('version','')} lastSeen={c.get('lastSeen') or c.get('lastSeenAt') or c.get('updatedAt','')}\")"
