#!/usr/bin/env bash
# Serve `containerlab graph` (interactive topology page) on http://127.0.0.1:50080.
# On Docker Desktop the host network of clab.sh is the VM's, so this variant
# publishes the port instead. Run from a phase directory; Ctrl-C stops it.
set -euo pipefail
CLAB_IMAGE="${CLAB_IMAGE:-ghcr.io/srl-labs/clab:0.83.0}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec docker run --rm --name ztf-graph -p 127.0.0.1:50080:50080 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$REPO_ROOT:$REPO_ROOT" -w "$PWD" \
  "$CLAB_IMAGE" containerlab graph -t "${1:-topology.clab.yml}" --srv 0.0.0.0:50080
