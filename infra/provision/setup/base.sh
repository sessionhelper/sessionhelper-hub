#!/usr/bin/env bash
# Base setup — runs on every provisioned server.
# Installs Docker, loads cached images, creates standard directories.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "=== base: updating packages ==="
apt-get update -qq
apt-get install -y -qq docker.io docker-compose-plugin jq curl > /dev/null

echo "=== base: enabling docker ==="
systemctl enable docker
systemctl start docker

echo "=== base: loading cached Docker images ==="
if [ -d /opt/cache/docker-images ]; then
  for img in /opt/cache/docker-images/*.tar.gz; do
    [ -f "$img" ] || continue
    echo "  loading $(basename "$img")..."
    docker load < "$img"
  done
fi

echo "=== base: creating directories ==="
mkdir -p /opt/ovp/models /opt/ovp/data

echo "=== base: done ==="
