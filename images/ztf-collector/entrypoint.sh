#!/bin/sh
# Same as the LinkMesh collector image: write the supervisor config from the
# environment and hand over to the OpAMP supervisor. The collector config itself
# comes from LinkMesh over OpAMP; nothing is configured by hand here.
# Difference to the chart's entrypoint: no `reports_remote_config` (opampsupervisor
# 0.165.0 refuses to start with it: deprecated, "remote config status is reported
# whenever accepts_remote_config is enabled").
set -e
: "${OPAMP_ENDPOINT:?OPAMP_ENDPOINT required}"
: "${LINKMESH_ENROLLMENT_TOKEN:?LINKMESH_ENROLLMENT_TOKEN required}"
mkdir -p /etc/otelcol-supervisor /var/lib/otelcol-supervisor
cat > /etc/otelcol-supervisor/supervisor.yaml <<CONF
server:
  endpoint: "${OPAMP_ENDPOINT}"
  headers:
    Authorization: "Bearer ${LINKMESH_ENROLLMENT_TOKEN}"
  tls:
    insecure: ${OPAMP_TLS_INSECURE:-true}   # false for a wss:// endpoint (external LinkMesh)
capabilities:
  accepts_remote_config: true
  reports_effective_config: true
  reports_health: true
  reports_own_metrics: true
agent:
  executable: /usr/local/bin/otelcol-contrib
  bootstrap_timeout: 30s
  description:
    non_identifying_attributes:
      linkmesh.environment: "${LINKMESH_ENVIRONMENT:-lab}"
      host.name: "${NODE_NAME:-$(hostname)}"
storage:
  directory: /var/lib/otelcol-supervisor
CONF
exec /usr/local/bin/opampsupervisor --config /etc/otelcol-supervisor/supervisor.yaml
