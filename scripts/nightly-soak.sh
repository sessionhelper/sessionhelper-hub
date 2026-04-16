#!/usr/bin/env bash
# nightly-soak.sh — run chronicle-bot soak harness nightly on dev.
#
# Drives the live dev stack through a multi-hour /record session and
# writes a JSON report to /var/log/chronicle-soak/.
#
# Intended to be invoked from cron on the dev VPS. Sample crontab line:
#   0 2 * * *  /opt/ovp/nightly-soak.sh
#
# Soak script + README: chronicle-bot/test-soak/

set -euo pipefail

SOAK_DIR=${SOAK_DIR:-/opt/ovp/test-soak}
LOG_DIR=${LOG_DIR:-/var/log/chronicle-soak}
DURATION_SECS=${DURATION_SECS:-10800}   # 3 hours
GUILD_ID=${GUILD_ID:-1489386428860338326}
CHANNEL_ID=${CHANNEL_ID:-1489386429682290932}
BOT_CONTAINER=${BOT_CONTAINER:-ovp-collector-1}

mkdir -p "$LOG_DIR"
stamp=$(date -u '+%Y-%m-%dT%H%M%SZ')
log="$LOG_DIR/soak-$stamp.log"
json="$LOG_DIR/soak-$stamp.json"

# Pre-flight: check-zombies so a stray local bot doesn't race the live one.
if [ -x /opt/ovp/check-zombies.sh ]; then
    /opt/ovp/check-zombies.sh --kill >> "$log" 2>&1 || true
fi

# Rotate old logs — keep 14 days.
find "$LOG_DIR" -name 'soak-*.log' -mtime +14 -delete 2>/dev/null || true
find "$LOG_DIR" -name 'soak-*.json' -mtime +14 -delete 2>/dev/null || true

GUILD_ID="$GUILD_ID" \
CHANNEL_ID="$CHANNEL_ID" \
BOT_CONTAINER="$BOT_CONTAINER" \
DURATION_SECS="$DURATION_SECS" \
python3 "$SOAK_DIR/soak.py" 2>&1 | tee -a "$log" | tail -n 200 > "$json"

# Exit code mirrors soak.py's.
exit ${PIPESTATUS[0]}
