#!/usr/bin/env bash
# Dev stack setup — full compose: postgres + data-api + collector + worker.
set -euo pipefail

# Run common base setup
source /opt/cache/setup/base.sh

echo "=== dev-stack: copying configs ==="
if [ -f /opt/cache/configs/docker-compose.yml ]; then
  cp /opt/cache/configs/docker-compose.yml /opt/ovp/
fi
if [ -f /opt/cache/configs/.env ]; then
  cp /opt/cache/configs/.env /opt/ovp/.env
  chmod 600 /opt/ovp/.env
fi

echo "=== dev-stack: copying models ==="
if [ -f /opt/cache/models/silero_vad_v6.onnx ]; then
  cp /opt/cache/models/silero_vad_v6.onnx /opt/ovp/models/
fi

echo "=== dev-stack: starting full compose stack ==="
if [ -f /opt/ovp/docker-compose.yml ]; then
  cd /opt/ovp && docker compose up -d
else
  echo "  WARN: no docker-compose.yml found, skipping compose up"
fi

echo "=== dev-stack: done ==="
