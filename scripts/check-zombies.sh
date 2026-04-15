#!/usr/bin/env bash
# check-zombies.sh — hunt for stale bot processes that would race our live
# instance for Discord gateway events.
#
# Symptom this defends against: live bot gets `Unknown interaction` 404s on
# ack because a zombie (usually an old build still running locally) acked
# the interaction first. Discord allows only one gateway session per token
# in steady state but transient overlap is enough to eat interactions.
#
# Run this before any interactive testing session. `--kill` removes the
# zombies; without it, just reports.

set -euo pipefail

KILL=0
if [[ "${1:-}" == "--kill" ]]; then
    KILL=1
fi

# Patterns matching old + new binary paths. Broad on purpose: the rename
# from `ttrpg-collector` to `chronicle-bot` left stale paths for anyone
# whose checkouts predate the rename.
PATTERNS='(ttrpg-collector(/|$)|chronicle-bot(/|$)|voice-capture/target/(debug|release)/(ttrpg-collector|chronicle-bot))'

# ps line format: PID ETIME USER CMD — filter out self + docker + editors.
ZOMBIES=$(
    ps axo pid,etime,user,cmd \
    | grep -E "$PATTERNS" \
    | grep -vE 'grep|docker compose|check-zombies|bash -c|cargo|target/release/build' \
    || true
)

if [[ -z "$ZOMBIES" ]]; then
    echo "No zombie bot processes found."
    exit 0
fi

echo "Found potential zombie bot processes:"
echo "$ZOMBIES"
echo ""

if [[ $KILL -eq 0 ]]; then
    echo "Rerun with --kill to terminate them."
    exit 1
fi

echo "Killing:"
while IFS= read -r line; do
    pid=$(echo "$line" | awk '{print $1}')
    echo "  kill $pid  ($(echo "$line" | awk '{for(i=4;i<=NF;++i) printf "%s ",$i; print ""}'))"
    kill "$pid" 2>/dev/null || echo "    (already gone)"
done <<< "$ZOMBIES"
