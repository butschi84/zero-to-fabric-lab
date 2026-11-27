#!/usr/bin/env bash
# Phase 9 observability stack, started after `make deploy PHASE=p9-observability`.
# Everything sits on the out-of-band management network (ztf-mgmt, 172.30.30.0/24):
#   .200 LinkMesh server        .201 collector site A   .202 collector site B
#   .203 gnmic site A           .204 gnmic site B
#   .210 Prometheus             .211 Grafana            .212 Loki
# The collectors get their whole pipeline from LinkMesh over OpAMP
# (obs/linkmesh/bootstrap.py); nothing is configured by hand in them.
# Lab-only credentials, published on 127.0.0.1 only.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../../.." && pwd)"
EV="$REPO/evidence/p9-observability"; mkdir -p "$EV/linkmesh"
NET=ztf-mgmt; LM_IMG=docker.io/opensight/linkmesh-server:1.501.1
run() { local n="$1" ip="$2"; shift 2; docker rm -f "ztf-p9-$n" >/dev/null 2>&1 || true
  docker run -d --name "ztf-p9-$n" --hostname "$n" --network "$NET" --ip "172.30.30.$ip" --restart unless-stopped "$@" >/dev/null; }

docker build -q -t ztf-collector:0.165.0 "$REPO/images/ztf-collector" >/dev/null
"$HERE/down.sh" >/dev/null   # a fresh LinkMesh needs fresh collector state
# LinkMesh: the lab's own server (default), or an external instance when LINKMESH_URL is set:
#   LINKMESH_URL=https://linkmesh.example LINKMESH_TOKEN=<api bearer token> make deploy PHASE=p9-observability
#   (or LINKMESH_EMAIL + LINKMESH_PASSWORD instead of LINKMESH_TOKEN). Credentials stay in the
#   environment: the enrollment tokens are minted at deploy time and only passed to the containers.
if [ -n "${LINKMESH_URL:-}" ]; then
  LMAPI="${LINKMESH_URL%/}"; OPAMP="$(echo "$LMAPI" | sed 's#^https://#wss://#; s#^http://#ws://#')/v1/opamp"
  TLSI=true; [ "${OPAMP#wss://}" != "$OPAMP" ] && TLSI=false
  export LM_TOKEN="${LINKMESH_TOKEN:-}" LM_EMAIL="${LINKMESH_EMAIL:-}" LM_PW="${LINKMESH_PASSWORD:-}"
else
  LMAPI=http://127.0.0.1:18080; OPAMP=ws://172.30.30.200:8080/v1/opamp; TLSI=true
run linkmesh 200 --platform linux/amd64 -p 127.0.0.1:18080:8080 -e ENVIRONMENT=production -e LINKMESH_STORAGE_BACKEND=bolt \
  -e LINKMESH_JWT_SECRET=zero-to-fabric-lab-only-jwt-secret-0001 -e LINKMESH_AUTH_LOCAL_ADMINEMAIL=admin@lab.local \
  -e LINKMESH_AUTH_LOCAL_ADMINPASSWORD=ZeroToFabric-lab1 -e LINKMESH_EXTERNALURL=http://172.30.30.200:8080 "$LM_IMG"
fi
run prometheus 210 -p 127.0.0.1:19090:9090 -v "$HERE/prometheus:/etc/prometheus:ro" prom/prometheus:v3.8.0 \
  --config.file=/etc/prometheus/prometheus.yml --web.enable-otlp-receiver --storage.tsdb.retention.time=7d
run loki 212 -v "$HERE/loki:/etc/loki:ro" grafana/loki:3.6.0 -config.file=/etc/loki/loki.yaml
run grafana 211 -p 127.0.0.1:13000:3000 -e GF_AUTH_ANONYMOUS_ENABLED=true -e GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer \
  -e GF_SECURITY_ADMIN_PASSWORD=ZeroToFabric-lab1 -e GF_USERS_DEFAULT_THEME=dark -e GF_ANALYTICS_REPORTING_ENABLED=false \
  -v "$HERE/grafana/provisioning:/etc/grafana/provisioning:ro" -v "$HERE/grafana/dashboards:/var/lib/grafana/dashboards:ro" grafana/grafana:12.3.0

until curl -sf "$LMAPI/health" >/dev/null; do sleep 2; done
tok() { LM_URL="$LMAPI" python3 -c "import sys;sys.path.insert(0,'$HERE/linkmesh');from lm import call;print(call('POST','/api/v1/enrollment-tokens',{'label':'$1'})['token'])"; }
for s in a b; do
  ip=$([ $s = a ] && echo 201 || echo 202)
  run collector-$s $ip -e OPAMP_ENDPOINT="$OPAMP" -e OPAMP_TLS_INSECURE=$TLSI -e LINKMESH_ENROLLMENT_TOKEN="$(tok zero-to-fabric-lab-site-$s)" \
    -e NODE_NAME=collector-$s -e LINKMESH_ENVIRONMENT=zero-to-fabric-lab -v ztf-p9-collector-$s:/var/lib/otelcol-supervisor ztf-collector:0.165.0
done
LM_URL="$LMAPI" python3 "$HERE/linkmesh/bootstrap.py" "$EV/linkmesh"

for s in a b; do
  run gnmic-$s $([ $s = a ] && echo 203 || echo 204) -v "$HERE/gnmic/gnmic-$s.yaml:/gnmic.yaml:ro" ghcr.io/openconfig/gnmic:0.50.0 --config /gnmic.yaml subscribe
done
# active probes, inside a client of each site (they measure the data path through leafs, DCI and IPsec)
probe() { docker rm -f "ztf-p9-probe-$1" >/dev/null 2>&1 || true
  docker run -d --name "ztf-p9-probe-$1" --net "container:clab-ztf-p9-$2" --cap-add NET_RAW --restart unless-stopped \
    quay.io/superq/smokeping-prober:v0.10.0 --ping.interval=1s "${@:3}" >/dev/null; }
probe a a-c1 10.1.1.21 10.1.3.21 10.1.10.11 10.1.2.11
probe b b-c1 10.1.1.11 10.1.2.11 10.1.10.11 10.1.3.21
for n in ipsec-a ipsec-b ipsec-br; do
  docker cp "$HERE/exporters/ipsec_exporter.py" "clab-ztf-p9-$n:/usr/local/bin/ipsec_exporter.py"
  docker exec "clab-ztf-p9-$n" sh -c 'pkill -f "[i]psec_exporter"; true'
  docker exec -d "clab-ztf-p9-$n" python3 /usr/local/bin/ipsec_exporter.py
done
echo "LinkMesh http://127.0.0.1:18080  Grafana http://127.0.0.1:13000  Prometheus http://127.0.0.1:19090"
