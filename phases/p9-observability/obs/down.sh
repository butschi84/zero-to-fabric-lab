#!/usr/bin/env bash
# Stop the phase 9 observability stack (before `make destroy PHASE=p9-observability`).
for c in $(docker ps -a --format '{{.Names}}' | grep '^ztf-p9-'); do docker rm -f "$c" >/dev/null; done
docker volume rm ztf-p9-collector-a ztf-p9-collector-b >/dev/null 2>&1 || true
echo "observability stack removed"
