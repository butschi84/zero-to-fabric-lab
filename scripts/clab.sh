#!/usr/bin/env bash
# Run containerlab from its official container image.
# Works on Linux and on macOS with Docker Desktop (arm64 + amd64): the
# container runs inside the Docker VM with the VM's network and PID namespace,
# so the network namespaces containerlab creates are the ones Docker uses.
set -euo pipefail
CLAB_IMAGE="${CLAB_IMAGE:-ghcr.io/srl-labs/clab:0.83.0}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TTY_FLAGS="-i"; [ -t 0 ] && TTY_FLAGS="-it"
exec docker run --rm $TTY_FLAGS --privileged \
  --network host --pid host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /var/run/netns:/var/run/netns \
  -v "$REPO_ROOT:$REPO_ROOT" -w "$PWD" \
  "$CLAB_IMAGE" containerlab "$@"
