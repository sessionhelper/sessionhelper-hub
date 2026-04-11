#!/usr/bin/env bash
# cache-build.sh — Populate the local cache from current Docker images,
# models, and configs. Run this before provisioning to speed up deploys.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/cache"

echo "=== Building provision cache ==="

# Docker images
mkdir -p "${CACHE_DIR}/docker-images"
save_image() {
  local image="$1" filename="$2"
  if docker image inspect "$image" > /dev/null 2>&1; then
    echo "  saving ${image} -> ${filename}..."
    docker save "$image" | gzip > "${CACHE_DIR}/docker-images/${filename}"
  else
    echo "  skipping ${image} (not found locally)"
  fi
}

save_image "ghcr.io/sessionhelper/chronicle-worker:dev" "chronicle-worker.tar.gz"
save_image "ghcr.io/sessionhelper/chronicle-data-api:dev" "chronicle-data-api.tar.gz"
save_image "postgres:16" "postgres-16.tar.gz"
save_image "fedirz/faster-whisper-server:latest" "faster-whisper-server.tar.gz"

# Models
mkdir -p "${CACHE_DIR}/models"
MODEL_SRC="/home/alex/chronicle-pipeline/models/silero_vad_v6.onnx"
if [ -f "$MODEL_SRC" ]; then
  echo "  copying silero_vad_v6.onnx..."
  cp "$MODEL_SRC" "${CACHE_DIR}/models/"
else
  echo "  skipping silero_vad_v6.onnx (not found at ${MODEL_SRC})"
fi

# Configs
mkdir -p "${CACHE_DIR}/configs"
COMPOSE_SRC="/home/alex/sessionhelper-hub/infra/dev-compose.yml"
if [ -f "$COMPOSE_SRC" ]; then
  echo "  copying docker-compose.yml..."
  cp "$COMPOSE_SRC" "${CACHE_DIR}/configs/docker-compose.yml"
else
  echo "  skipping docker-compose.yml (not found at ${COMPOSE_SRC})"
fi

echo ""
echo "=== Cache contents ==="
du -sh "${CACHE_DIR}"/* 2>/dev/null || echo "(empty)"
echo ""
echo "Done. Run 'provision.sh up <profile>' to provision a server."
