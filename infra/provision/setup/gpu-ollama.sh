#!/usr/bin/env bash
# GPU / Ollama setup — installs Ollama, loads cached models, pulls qwen2.5:7b.
set -euo pipefail

# Run common base setup
source /opt/cache/setup/base.sh

echo "=== gpu-ollama: installing NVIDIA container toolkit ==="
# Only attempt GPU setup if an NVIDIA GPU is detected
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
  echo "  No NVIDIA GPU detected — Ollama will run in CPU mode"
fi

echo "=== gpu-ollama: installing Ollama ==="
curl -fsSL https://ollama.com/install.sh | sh

echo "=== gpu-ollama: loading cached models ==="
if [ -d /opt/cache/models/ollama ]; then
  mkdir -p /usr/share/ollama/.ollama/models
  cp -r /opt/cache/models/ollama/* /usr/share/ollama/.ollama/models/ 2>/dev/null || true
fi

echo "=== gpu-ollama: starting Ollama ==="
systemctl enable ollama
systemctl start ollama

# Wait for Ollama to be ready
for i in $(seq 1 30); do
  if curl -sf http://localhost:11434/api/tags > /dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "=== gpu-ollama: pulling qwen2.5:7b ==="
ollama pull qwen2.5:7b || echo "  WARN: model pull failed — may need to pull manually"

echo "=== gpu-ollama: done ==="
