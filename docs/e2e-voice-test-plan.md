# End-to-end voice-capture test plan

Test matrix for the voice-join/leave lifecycle. Written 2026-04-18 after
the Phase 0 multi-user DAVE exit-criterion test surfaced gaps in
participant enrolment that weren't covered by any existing test.

Two layers: **unit tests** (pure functions, fast, in-repo) and **E2E
scenarios** (live Discord + data-api + worker, driven by the harness or
slash commands). Unit tests run in CI; E2E scenarios are manual triggers
until the nightly soak is mature enough to fold them in.

---

## Unit test coverage (Rust)

All landed in `chronicle-bot/voice-capture/src/session/actor.rs` behind
`#[cfg(test)] mod tests`. The pure `voice_state_transition()` decision
function takes `(participants, session_channel, new_channel, user_id, is_bot)`
and returns a `VoiceStateAction`. Tests assert the decision table.

| Case | Inputs | Expected action |
|---|---|---|
| Bot voice-state | `is_bot=true` | `Ignore` |
| Human enters, no prior participant | new user joins session ch | `EnrolAndTrack` |
| Human enters, already a participant | rejoin after leave | `TrackAsHuman` |
| Human moves to different channel, never was ours | unrelated | `Drop` |
| Pending leaves session channel | auto-enrolled but no consent | `ImplicitDeclineAndDrop` |
| Accepted leaves session channel | consented → left | `Drop` (preserve consent) |
| Already-Declined leaves | previously declined | `Drop` (no-op) |
| Pending switches to different channel | equivalent to disconnect | `ImplicitDeclineAndDrop` |

All 8 unit tests pass in the committed changeset.

---

## E2E scenarios (manual, live dev)

Each scenario runs against the dev VPS + live Discord. Pre-conditions:

- `bash /opt/ovp/check-zombies.sh` clean
- Whisper tunnel up (`ssh root@dev.sessionhelper.com "curl -sf http://127.0.0.1:8300/health"`)
- Feeder `AUDIO_FILE`s configured for whichever fixture the scenario needs (short clips for fast runs, 1hr Kokoro for sustained runs)
- For **headless harness runs under `require_all_consent=true`**, the driver must POST `/consent` for every feeder participant after they register — see §E2E drivers below. Without this, chunks stay Pending and the ingest assertion fails.

### Scenario group A — Happy path

**A1. Solo slash `/record`.**
- 1 human present when `/record` fires
- expect: consent embed posted, Accept → gate opens → recording → /stop → `status=transcribed`, `segs > 0`
- already covered by yesterday's live session `0c665285`

**A2. Two-person slash `/record`, both Accept.**
- 2 humans in voice before `/record`
- expect: both get consent buttons, both Accept → gate opens, both tracks upload, mix track aggregates, transcripts per speaker
- validates gate quorum logic

**A3. Harness `/record` + 4 staggered feeders.**
- harness `/record`, then feeders 1-4 join one-at-a-time with 5s stagger (MLS constraint)
- feeders play different audio simultaneously
- expect: all 4 auto-enrolled on voice-join (the bug this fix closes), 4 participant rows, 4 per-speaker chunk streams, mix track, segments
- previously failed pre-fix (0 chunks); now should succeed

### Scenario group B — Late joiners

**B1. Slash `/record` then late joiner.**
- 1 human present at `/record`, 2nd human joins 30s after gate opens
- expect: late joiner auto-enrolled post-gate, data-api participant row created, their cache starts capturing, consent embed shown to them
- confirms `apply_enrol`'s post-gate branch (`session_uuid_opt.is_some()`) fires correctly

**B2. Harness `/record` with staggered-join + mid-session 5th feeder.**
- 4 feeders join as in A3, then a 5th feeder is launched 2 minutes into recording
- expect: 5th gets auto-enrolled, their audio routes, chunks land
- validates that auto-enrol works past the initial session spawn

### Scenario group C — Leaves

**C1. Pending leaves before gate opens.**
- 2 humans present at `/record`, user 2 leaves voice before clicking consent
- expect: user 2's `scope` set to Decline via implicit-decline path, `expected_user_ids` removes user 2, gate opens on user 1 alone (if MIN_PARTICIPANTS=1)
- this is the concrete "stabilization timeout" fix

**C2. Accepted leaves mid-recording, session continues.**
- 2 humans Accept, both talk for 1 min, user 2 disconnects
- expect: session keeps recording user 1's audio, user 2's consent preserved as Accepted, user 2's cache / uploads remain valid, user 2's audio stops producing chunks (they disconnected)
- session should NOT auto-stop (user 1 still present)

**C3. Everyone leaves: auto-stop.**
- 2 humans Accept, both leave voice mid-recording
- expect: auto-stop grace timer starts (30s default), then session finalizes via `SessionCmd::AutoStop`
- the `recompute_humans_and_auto_stop_timer` path

**C4. Initiator leaves, others remain.**
- 3 humans present, initiator Accepts then disconnects
- expect: recording continues; other participants can still `/stop`-equivalent behavior via admin (if roles allow) or auto-stop when they leave too

### Scenario group D — Rejoins

**D1. Accepted user leaves + rejoins mid-session.**
- 1 human Accepts, records 30s, disconnects, reconnects 10s later
- expect: no duplicate enrolment (`TrackAsHuman` not `EnrolAndTrack`), SSRC remaps to same user_id on rejoin, chunks continue in same per-speaker track

**D2. Pending user leaves + rejoins before consenting.**
- 2 humans present, user 2 disconnects before Accept, reconnects 20s later
- expect: user 2's first leave triggered implicit-decline; on rejoin they are NOT auto-re-enrolled (per `session.participants.contains_key` guard) — their Declined state persists
- this is the edge case worth scrutiny: is it *right* that rejoining doesn't reopen consent? Spec answer: yes. Implicit-decline is terminal; they'd need a fresh `/record` session to reconsent.

### Scenario group E — Cross-channel

**E1. User switches to a different voice channel mid-session.**
- 1 human Accepts in the session channel, then moves to a different voice channel
- expect: `ImplicitDeclineAndDrop` does NOT fire (they already Accepted); their cache remains valid; session auto-stops on grace timer because nobody consented is in the session channel anymore
- **note:** current `voice_state_transition` table has Accepted+LeftToOtherChannel → `Drop`. That's correct behavior.

**E2. User rapidly toggles channels.**
- user joins session channel, leaves, joins, leaves — all inside 2 seconds
- expect: debouncing NOT required at this layer (SessionCmd queue processes in order, decision is stateless per-event); final state reflects last transition

### Scenario group F — Bot hygiene

**F1. Zombie on local machine.**
- local stale `target/release/chronicle-bot` process running with dev token
- expect: `check-zombies.sh` reports + kills; subsequent `/record` ack doesn't get intercepted
- procedure enforced by `nightly-soak.sh` preflight

**F2. Gateway RESUME during active session.**
- run a long session, observe a `Resumed` gateway event (they occur ~hourly on our tunnel)
- expect: `interactions_deduped_total` counter ticks up if an interaction was replayed, no duplicate session spawn

---

## E2E driver sketches

### Harness-driven (fast feedback, no humans)

Sequence for scenarios A3, B2, C-series with feeder-disconnect, D-series
with feeder-reconnect:

```bash
# On dev:
cd /opt/ovp
# 1. Clean pre-flight
bash /opt/ovp/check-zombies.sh --kill

# 2. Spawn session
curl -sX POST http://127.0.0.1:8010/record \
  -H 'content-type: application/json' \
  -d '{"guild_id":..., "channel_id":...}'
# → { "session_id": "..." }

# 3. Feeder joins (staggered, per MLS constraint)
for port in 8003 8004 8005 8006; do
  curl -sX POST "http://127.0.0.1:$port/join" \
    -H 'content-type: application/json' \
    -d '{"guild_id":..., "channel_id":...}'
  sleep 5
done

# 4. PATCH consent for every feeder participant.
#    REQUIRED when data-api has require_all_consent=true: chunks stay in
#    Pending status until every participant either Accepts or Declines,
#    and the 1hr multi-user DAVE test failed the chunk-ingestion assertion
#    on Attempt 3 because this step was missing. Emulates the consent-embed
#    button click for headless feeders.
#
# Data-API is on :8001 (dev). Internal endpoints require a service session
# token obtained from POST /internal/auth with the shared secret. Consent
# PATCH is a no-auth public endpoint keyed by the per-participant token.
DATA_API="http://127.0.0.1:8001"
SID="<session_id from step 2>"   # or look it up: /internal/sessions?active=1

# 4a. Mint a service session token.
TOK=$(curl -s -X POST "$DATA_API/internal/auth" \
        -H 'content-type: application/json' \
        -d "{\"shared_secret\":\"$SHARED_SECRET\",\"service_name\":\"soak-harness\"}" \
      | jq -r .session_token)
AUTH=(-H "authorization: Bearer $TOK")

# 4b. Fetch participants, mint a consent token per pseudo_id, PATCH consent.
curl -s "${AUTH[@]}" "$DATA_API/internal/sessions/$SID/participants" \
  | jq -c '.[] | {id, pseudo_id}' \
  | while read -r row; do
      PID=$(jq -r .id <<<"$row")
      PSEUDO=$(jq -r .pseudo_id <<<"$row")
      CT=$(curl -s -X POST "$DATA_API/internal/consent-tokens" \
             "${AUTH[@]}" -H 'content-type: application/json' \
             -d "{\"session_id\":\"$SID\",\"participant_id\":\"$PID\",\"pseudo_id\":\"$PSEUDO\"}" \
           | jq -r .token)
      curl -s -X PATCH "$DATA_API/public/consent/$CT" \
        -H 'content-type: application/json' \
        -d '{"consent_scope":"full"}' >/dev/null
    done

# 5. Feeders play
for port in 8003 8004 8005 8006; do
  curl -sX POST "http://127.0.0.1:$port/play"
done

# 6. Leave-scenario: kill one feeder mid-run
curl -sX POST http://127.0.0.1:8004/leave

# 7. Rejoin-scenario: have it rejoin
sleep 10
curl -sX POST http://127.0.0.1:8004/join \
  -H 'content-type: application/json' \
  -d '{"guild_id":..., "channel_id":...}'
curl -sX POST http://127.0.0.1:8004/play

# 8. Stop session
curl -sX POST http://127.0.0.1:8010/stop \
  -H 'content-type: application/json' \
  -d '{"guild_id":...}'
```

### Assertions (for all E2E)

After each scenario, verify via data-api:

1. `GET /internal/sessions/<sid>` → status is `transcribed` (worker ran) OR `uploaded` (chunks present, pipeline pending).
2. `GET /internal/sessions/<sid>/participants` → count matches expected participants for the scenario. `scope` field matches the scenario's expected consent outcome.
3. `GET /internal/sessions/<sid>/audio/<pseudo_id>/chunks` → chunk count > 0 for every participant who was supposed to produce audio. `duration_ms` sum approximately matches how long they were in voice.
4. Segments table → `count > 0` for every Accepted participant (assuming Whisper was reachable).
5. Collector logs filtered for the session_id → no `ERROR`, no `stabilization_timeout`, no `dave_heal_fired` above the debounce threshold.

---

## Wiring into nightly soak

Today `/opt/ovp/nightly-soak.sh` runs a 3hr single-scenario `/record` →
play → `/stop` cycle at 02:00 UTC. Next increment: extend the wrapper to
iterate a small matrix (A3, C2, D1) with short durations, writing a
combined pass/fail JSON to `/var/log/chronicle-soak/soak-*.json`.
Blocking task: the soak script's TODOs for DAVE-heal counter scrape and
silent-rollup detection — land those first, then extend the matrix.

---

## Known gaps (follow-ups)

- No E2E harness test for **two users with overlapping speech through DAVE**. The 1hr Kokoro fixture covers this for the solo-enrolment case but not explicitly for user-leave-mid-overlap edge cases.
- No coverage for **Discord SSRC rotation** — if Discord ever rotates a user's SSRC mid-session (unusual but documented), the receiver's `ssrc_to_user` map wouldn't auto-update. `SpeakingTracker` adds on OP5; stale entries linger. Pragmatically not a hot issue; log-only for now.
- **Worker re-auth loop** (`invalid session token` on heartbeat) surfaced during the 1hr test is out of scope for this doc — tracked separately.
