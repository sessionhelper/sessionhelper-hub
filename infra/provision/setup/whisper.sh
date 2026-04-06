#!/usr/bin/env bash
# Whisper setup — faster-whisper-server for transcription.
set -euo pipefail

# Run common base setup
source /opt/cache/setup/base.sh

echo "=== whisper: installing NVIDIA container toolkit ==="
if lspci 2>/dev/null | grep -qi nvidia; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
  apt-get update -qq
  apt-get install -y -qq nvidia-container-toolkit > /dev/null
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
  echo "  GPU support configured"
else
  echo "  No NVIDIA GPU detected — whisper will run in CPU mode"
fi

echo "=== whisper: copying models ==="
if [ -f /opt/cache/models/silero_vad_v6.onnx ]; then
  cp /opt/cache/models/silero_vad_v6.onnx /opt/ovp/models/
fi

echo "=== whisper: starting faster-whisper-server ==="
# Run faster-whisper-server as a Docker container.
# GPU flag is conditional on hardware availability.
DOCKER_GPU_FLAG=""
if lspci 2>/dev/null | grep -qi nvidia; then
  DOCKER_GPU_FLAG="--gpus all"
fi

docker run -d \
  --name faster-whisper-server \
  --restart unless-stopped \
  ${DOCKER_GPU_FLAG} \
  -p 8000:8000 \
  -v /opt/ovp/models:/models \
  fedirz/faster-whisper-server:latest || echo "  WARN: faster-whisper-server image not cached and pull may fail"

echo "=== whisper: done ==="
