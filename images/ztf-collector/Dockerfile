# Collector for the lab: upstream otelcol-contrib under the upstream OpAMP
# supervisor, enrolled into LinkMesh. Same composition and entrypoint as the
# LinkMesh collector image (the image/ folder of the LinkMesh collector Helm chart), built
# here because docker.io/opensight/linkmesh-collector is not anonymously
# pullable yet. Version 0.165.0: what LinkMesh 1.501.1 recommends (0.153.0, the chart's
# appVersion, is flagged by LinkMesh for advisory GHSA-vf52-ppm4-c35w).
ARG OTELCOL_VERSION=0.165.0
FROM alpine:3.22 AS fetch
ARG OTELCOL_VERSION
ARG TARGETARCH
RUN apk add --no-cache curl ca-certificates \
 && B=https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download \
 && curl -fsSL "$B/v${OTELCOL_VERSION}/otelcol-contrib_${OTELCOL_VERSION}_linux_${TARGETARCH}.tar.gz" | tar -xz -C /usr/local/bin otelcol-contrib \
 && curl -fsSL -o /usr/local/bin/opampsupervisor "$B/cmd%2Fopampsupervisor%2Fv${OTELCOL_VERSION}/opampsupervisor_${OTELCOL_VERSION}_linux_${TARGETARCH}" \
 && chmod 0755 /usr/local/bin/otelcol-contrib /usr/local/bin/opampsupervisor

FROM debian:bookworm-slim
COPY --from=fetch /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=fetch /usr/local/bin/otelcol-contrib /usr/local/bin/opampsupervisor /usr/local/bin/
COPY --chmod=0755 entrypoint.sh /entrypoint.sh
EXPOSE 4317 4318
ENTRYPOINT ["/entrypoint.sh"]
