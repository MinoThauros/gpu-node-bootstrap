#!/usr/bin/env bash
# Switches the GPU to one mode: stops every profile, then starts the one asked for,
# so two modes never compete for GPU memory.
# Usage: sudo ./gpu-mode.sh serve|ingest|off
set -euo pipefail
cd "$(dirname "$0")"

mode="${1:?usage: gpu-mode.sh serve|ingest|off}"
docker compose --profile serve --profile ingest down
if [ "$mode" != off ]; then
  docker compose --profile "$mode" up -d
fi
docker compose --profile serve --profile ingest ps
