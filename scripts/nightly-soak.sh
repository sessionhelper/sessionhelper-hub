#!/usr/bin/env bash
# nightly-soak.sh — run chronicle-bot soak harness nightly on dev.
#
# Two phases per run:
#   1. Short scenario matrix (matrix.py: A3, C2, D1 from e2e-voice-test-plan.md)
#      — catches voice-state edge-case regressions fast.
#   2. Long single-scenario soak (soak.py) — catches leaks, drift, DAVE heal
#      from extended operation.
#
# Both phases write their JSON to /var/log/chronicle-soak/. The matrix runs
# first because its failures are the cheapest to diagnose; if it fails we
# still run the long soak but surface the matrix failures in the combined
# exit code.
#
# Intended to be invoked from cron on the dev VPS. Sample crontab line:
#   0 2 * * *  /opt/ovp/nightly-soak.sh
#
# Soak scripts + README: chronicle-bot/test-soak/

set -uo pipefail

SOAK_DIR=${SOAK_DIR:-/opt/ovp/test-soak}
LOG_DIR=${LOG_DIR:-/var/log/chronicle-soak}
DURATION_SECS=${DURATION_SECS:-10800}   # 3 hours
SCENARIO_DURATION_SECS=${SCENARIO_DURATION_SECS:-180}
GUILD_ID=${GUILD_ID:-1489386428860338326}
CHANNEL_ID=${CHANNEL_ID:-1489386429682290932}
BOT_CONTAINER=${BOT_CONTAINER:-ovp-collector-1}
DATA_API_CONTAINER=${DATA_API_CONTAINER:-ovp-data-api-1}

mkdir -p "$LOG_DIR"
stamp=$(date -u '+%Y-%m-%dT%H%M%SZ')
matrix_log="$LOG_DIR/matrix-$stamp.log"
matrix_json="$LOG_DIR/matrix-$stamp.json"
soak_log="$LOG_DIR/soak-$stamp.log"
soak_json="$LOG_DIR/soak-$stamp.json"

# Pre-flight: check-zombies so a stray local bot doesn't race the live one.
if [ -x /opt/ovp/check-zombies.sh ]; then
    /opt/ovp/check-zombies.sh --kill >> "$matrix_log" 2>&1 || true
fi

# Rotate old logs — keep 14 days.
find "$LOG_DIR" -name '*.log' -mtime +14 -delete 2>/dev/null || true
find "$LOG_DIR" -name '*.json' -mtime +14 -delete 2>/dev/null || true

# Pull the data-api shared secret once; matrix.py needs it to mint service
# session tokens for the consent-patch step.
SHARED_SECRET=$(docker exec "$DATA_API_CONTAINER" printenv SHARED_SECRET 2>/dev/null || echo "")

matrix_status=0
if [ -n "$SHARED_SECRET" ] && [ -f "$SOAK_DIR/matrix.py" ]; then
    echo "=== phase 1: scenario matrix ===" >> "$matrix_log"
    GUILD_ID="$GUILD_ID" \
    CHANNEL_ID="$CHANNEL_ID" \
    BOT_CONTAINER="$BOT_CONTAINER" \
    SHARED_SECRET="$SHARED_SECRET" \
    SCENARIO_DURATION_SECS="$SCENARIO_DURATION_SECS" \
    python3 "$SOAK_DIR/matrix.py" 2>&1 \
        | tee -a "$matrix_log" \
        | tail -n 400 > "$matrix_json"
    matrix_status=${PIPESTATUS[0]}
    echo "matrix exit=$matrix_status" >> "$matrix_log"
else
    echo "matrix skipped: missing SHARED_SECRET or matrix.py" >> "$matrix_log"
fi

echo "=== phase 2: long soak (${DURATION_SECS}s) ===" >> "$soak_log"
GUILD_ID="$GUILD_ID" \
CHANNEL_ID="$CHANNEL_ID" \
BOT_CONTAINER="$BOT_CONTAINER" \
DURATION_SECS="$DURATION_SECS" \
python3 "$SOAK_DIR/soak.py" 2>&1 | tee -a "$soak_log" | tail -n 200 > "$soak_json"
soak_status=${PIPESTATUS[0]}
echo "soak exit=$soak_status" >> "$soak_log"

# Combined exit: non-zero if either phase failed.
if [ "$matrix_status" -ne 0 ] || [ "$soak_status" -ne 0 ]; then
    exit 1
fi
exit 0
