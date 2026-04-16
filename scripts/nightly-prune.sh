#!/usr/bin/env bash
# nightly-prune.sh — reclaim docker image + buildkit cache disk space on dev.
#
# Background: dev VPS is a Hetzner CPX11 with a 38G root partition. The
# deploy workflow pulls fresh ghcr images on every main push, which over
# time accumulates in /var/lib/docker/overlay2. On 2026-04-15 the disk
# hit 100% and postgres PANIC'd with "could not write ... No space left
# on device". Manual `docker image prune -a -f` reclaimed 5.5GB.
#
# This script runs nightly to stop that recurring. It keeps anything
# pulled in the last 48h (in case a rollback is needed) and drops the
# rest. Buildkit cache is pruned at 7 days.
#
# Intended to be invoked from cron on the dev VPS. Sample crontab line:
#   15 3 * * *  /opt/ovp/nightly-prune.sh
# (03:15 UTC — right after the 02:00 nightly-soak has finished.)
#
# Deliberately does NOT use `docker system prune`: too aggressive, and on
# older docker versions it can nuke unused volumes (postgres data!).
#
# VPS copy lives at /opt/ovp/nightly-prune.sh — same pattern as
# nightly-soak.sh.

set -euo pipefail

LOG_DIR=${LOG_DIR:-/var/log/chronicle-prune}
IMAGE_KEEP=${IMAGE_KEEP:-48h}      # keep images pulled in last 48h
BUILDER_KEEP=${BUILDER_KEEP:-168h} # keep buildkit cache from last 7 days

mkdir -p "$LOG_DIR"
stamp=$(date -u '+%Y-%m-%dT%H%M%SZ')
log="$LOG_DIR/prune-$stamp.log"

exec > >(tee -a "$log") 2>&1

echo "=== nightly-prune.sh @ $stamp ==="
echo "--- disk before ---"
df -h /
echo
echo "--- docker system df before ---"
docker system df || true
echo

echo "--- docker image prune -a -f --filter until=$IMAGE_KEEP ---"
docker image prune -a -f --filter "until=$IMAGE_KEEP"
echo

echo "--- docker builder prune -a -f --filter until=$BUILDER_KEEP ---"
docker builder prune -a -f --filter "until=$BUILDER_KEEP"
echo

echo "--- disk after ---"
df -h /
echo
echo "--- docker system df after ---"
docker system df || true
echo

# Rotate old prune logs — keep 14 days.
find "$LOG_DIR" -name 'prune-*.log' -mtime +14 -delete 2>/dev/null || true

echo "=== nightly-prune.sh done ==="
