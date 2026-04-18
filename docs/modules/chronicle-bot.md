# chronicle-bot

Discord voice-capture bot. Captures DAVE/MLS-encrypted per-speaker audio from Discord voice channels, gates release on participant consent, and hands off to `chronicle-data-api` for storage.

Status: **Features and Interfaces locked. Behavior pending.** Implementation owner: `chronicle-bot/voice-capture/`.

---

## Features

1. **Voice session lifecycle.** Joins a Discord voice channel on demand, captures audio for its duration, stops + finalizes on request or when the channel empties.

2. **Audio capture decoupled from consent gating, buffered on disk.** Audio acquisition starts the moment the DAVE handshake completes and continues for every participant in the channel. Decrypted PCM chunks are written to a per-session temp directory (`$LOCAL_BUFFER_DIR/<session_id>/<pseudo_id>/chunk_<seq>.pcm`), one participant per subdirectory. On Accept, the cached chunks stream to `chronicle-data-api` in sequence order, then delete. On Decline or timeout, the participant's subdirectory is removed. When `/stop` fires or the session ends, the entire session's temp dir is cleaned up regardless of outcome. Keeps RAM flat; bounded only by disk headroom.

3. **Per-speaker audio capture, concurrent by design.** Each participant's capture pipeline — decrypt, de-mux, chunk, cache, flush — runs as its own task. Independent operations are never serialized behind `.await` inside the same coroutine; they're spawned or joined. Memory overhead from per-speaker task state is accepted as the price of parallelism. Applies across all async code in the bot.

4. **License flags as session metadata, decoupled from capture.** On Accept, the participant is immediately recorded with consent scope + default license flags (`no_llm_training=false`, `no_public_release=false`). Flags can be mutated later via buttons or the portal. The capture pipeline is oblivious to license flags — they gate *release* decisions, not recording. The Accept interaction is a single click; no followup prompt.

5. **Data API hand-off.** Session rows, participant rows, consent events, license flags, PCM chunks, and session metadata are persisted via `chronicle-data-api` using a shared-secret auth token. The bot does not talk to S3 or Postgres directly.

6. **Stabilization gate before "Recording started" announcement.** Before the gate, the bot may freely leave, rejoin, retry DAVE handshake, or reconnect to heal SSRC mappings — the user hasn't been told recording is live, so disruption is free. The gate opens only after all expected audio channels have been healthy (producing decoded frames mapped to their users) for a few seconds continuously. When the gate opens, the announcement plays; from that moment the user has a firm expectation that audio is being captured. Post-gate disruptions are logged and mitigated silently, but capture continuity is a hard invariant — once the gate opens, chunks flow end-to-end.

7. **Auto-stop.** When the voice channel empties (no consenting humans present), the session finalizes automatically after a fixed grace period.

8. **Dev-only E2E HTTP harness.** When `HARNESS_ENABLED=true`, the bot exposes a loopback-only HTTP control surface that invokes the same pipelines as the Discord slash/button interactions, bypassing Discord entirely. The test scaffold in `chronicle-feeder` drives the full user flow — including consent and license preferences — through this surface. There is no human-bypass list; programmatic testing goes through the harness, not through privileged user IDs.

9. **Observability.** Emits structured `tracing` logs per session-lifecycle event; emits metrics for sessions started, sessions finalized, consent responses, chunks uploaded, pre-consent cache disk usage, and interaction ack latency.

---

## Interfaces

### Inbound — Discord gateway (via serenity)

- Slash commands: `/record`, `/stop`
- Component interactions: `consent_accept`, `consent_decline`, `license_no_llm`, `license_no_public`
- Voice state updates
- Voice ticks (per-speaker decrypted audio frames, via songbird)
- Ready event (command registration on startup)

### Inbound — dev harness HTTP (`HARNESS_ENABLED=true`, loopback-only)

All harness endpoints flow through the same `SessionCmd` actor surface as the Discord handlers, so tests exercise the real user-flow code path.

- `GET /health` → `{ ready, harness_enabled }`
- `POST /record` `{ guild_id, channel_id }` → `{ session_id }`
- `POST /enrol` `{ guild_id, user_id, display_name, is_bot }` → `{ participant_id }` — explicit participant registration for test users who aren't in Discord voice. Invokes the same enrolment code used by `/record`'s member scan.
- `POST /consent` `{ guild_id, user_id, scope: "full"|"decline" }` → `{ ok }`
- `POST /license` `{ guild_id, user_id, field, value }` → `{ ok }`
- `POST /stop` `{ guild_id }` → `{ ok }`

### Outbound — `chronicle-data-api` (one client, shared-secret auth)

- `POST /internal/auth` + `POST /internal/heartbeat`
- `POST /internal/users`
- `POST /internal/sessions`, `PATCH /internal/sessions/{id}`
- `POST /internal/sessions/{id}/participants/batch`
- `PATCH /internal/participants/{id}/consent`
- `PATCH /internal/participants/{id}/license`
- `POST /internal/sessions/{id}/audio/{pseudo_id}/chunk` (raw PCM body)
- `POST /internal/sessions/{id}/metadata`

### Outbound — Discord API (via serenity)

- Interaction responses (defer/ack, edit, followup) — **always via the interaction wrapper below**
- Voice channel connect/disconnect (via songbird)
- Text channel messages (session-level announcements)

### Interaction wrapper (consolidated, "one bubble")

Every Discord interaction (command or component) goes through one helper:

```rust
pub async fn respond<F, Fut>(
    ctx: &Context,
    interaction: &impl Interactionable,
    handler: F,
) -> Result<(), serenity::Error>
where
    F: FnOnce(InteractionCtx) -> Fut,
    Fut: Future<Output = InteractionReply>;
```

The wrapper:

1. Acks Discord first (`Defer` for commands, `Acknowledge` for components) — always the first outbound call.
2. Invokes `handler`, which returns an `InteractionReply` enum (`Edit(content)`, `UpdateMessage(content)`, `Followup(content, ephemeral)`, `Silent`).
3. Converts the reply into the right Discord API call (`edit_response`, followup, etc.).
4. Captures + logs timing + errors uniformly.

Handlers never call `create_response` / `edit_response` / `create_followup` directly. They return a reply value. This eliminates the defer-first footgun entirely and gives every interaction the same error/observability envelope.

### Environment variables

| Var | Required | Default | Meaning |
|---|---|---|---|
| `DISCORD_TOKEN` | yes | — | Bot token |
| `DATA_API_URL` | yes | — | Base URL of chronicle-data-api |
| `DATA_API_SHARED_SECRET` | yes | — | Cross-service auth secret |
| `LOCAL_BUFFER_DIR` | no | `$TMPDIR/chronicle-bot` (usually `/tmp/chronicle-bot`) | Root dir for per-session pre-consent chunk cache |
| `LOCAL_BUFFER_MAX_SECS` | no | `7200` | Per-participant cap before oldest-first drop |
| `HARNESS_ENABLED` | no | `false` | Enables dev HTTP harness |
| `HARNESS_BIND` | no | `127.0.0.1:8010` | Harness listen address |
| `MIN_PARTICIPANTS` | no | `1` | Minimum consenting humans before the gate will open. **Dev runs at 1 (solo testing); prod should stay at 2** so a single-person "recording" isn't a surprising outcome. Set in `/opt/ovp/.env` per environment. |
| `REQUIRE_ALL_CONSENT` | no | `true` | Gate waits for unanimity among detected humans. Flip to `false` for permissive-consent scenarios where one decliner shouldn't abort the whole session. |
| `RUST_LOG` | no | `chronicle_bot=info` | tracing filter |

Dropped vs prior version: `BYPASS_CONSENT_USER_IDS` (no more bypass list — harness supersedes).

### Observability

Tracing spans:

- `session_actor{session_id, guild_id}`
- `interaction{interaction_id, kind}`
- `participant_capture{pseudo_id}`

Metrics:

- `chronicle_sessions_total{outcome}` — counter
- `chronicle_audio_packets_received` — counter
- `chronicle_consent_responses_total{scope}` — counter
- `chronicle_sessions_active` — gauge
- `chronicle_prerolled_chunks_cached_bytes` — gauge (disk usage, sums filesystem per-session dir sizes)
- `chronicle_prerolled_chunks_dropped_total` — counter (increments when MAX_SECS cap trims)
- `chronicle_interaction_ack_us` — histogram (proves we stay well under Discord's 3s window)

---

## Behavior

### Session phase state machine

```
           /record or harness POST /record
                    │
                    ▼
          ┌────────────────────────┐
          │  AwaitingStabilization │◄──── leave/rejoin/retry DAVE
          │                        │      (pre-gate: disruption is free)
          │  - voice joining       │
          │  - DAVE handshake      │
          │  - per-speaker pipelines│
          │    caching to disk     │
          │  - consent in parallel │
          └──────────┬─────────────┘
                     │  gate opens (N seconds of healthy channels)
                     │  → announcement plays
                     ▼
          ┌────────────────────────┐
          │      Recording         │◄── heal silently, announcement never replays
          │                        │
          │  - chunks flow live    │
          │  - consented: stream   │
          │  - pending: cached     │
          └──────────┬─────────────┘
                     │  /stop OR auto-stop (empty channel) OR catastrophic failure
                     ▼
          ┌────────────────────────┐         ┌─────────────────────────┐
          │      Finalizing        │         │       Restarting        │
          │                        │         │                         │
          │  - drain pending chunks│         │  - announce failure     │
          │  - POST metadata       │         │  - carry participants + │
          │  - cleanup buffer dir  │         │    consent records      │
          │  - deregister actor    │         │  - spawn new session    │
          └──────────┬─────────────┘         │    (new session_id)     │
                     │                        └──────────┬──────────────┘
                     ▼                                   │
          (actor exits, handle removed)   rejoin, gate, play announcement
                                                         │
                                                         └──> Recording
```

Side paths:

- **Stabilization timeout:** if stabilization never completes within a hard timeout (default `180s`), `AwaitingStabilization → Cancelled`. Session row marked `abandoned` in data-api. No announcement, no user-visible recording. Buffer dir deleted.
- **Restart budget:** carry-forward capped at **1 restart per guild per hour**. A second catastrophic failure within that window posts "Session unrecoverable — please `/record` again" and exits without rejoining.

### Catastrophic recovery

When the bot detects a catastrophic session failure after the stabilization gate has opened — actor panic caught by supervisor, voice connection drop that heal cannot recover within N attempts, data-api 5xx storm past the retry budget — it transitions through a dedicated `Restarting` state rather than dying silently:

1. Posts to the session's text channel: **"Something went catastrophically wrong, restarting session."**
2. Spawns a new session actor with a new `session_id`, **carrying forward the existing participant list + consent records + license flags** from the failed session. No consent prompt is re-shown.
3. Rejoins voice, runs stabilization gate, plays the "recording started" announcement (same as a fresh session — users need to know recording is live again).
4. On restart, only already-Accepted participants have capture pipelines; Declined stays Declined; Pending is treated as Decline (they had their chance).
5. The failed session's `session_id` is marked `abandoned` in the data-api. Its buffer dir is deleted. Chunks already uploaded under that session_id remain in S3 under their original prefix.
6. Carry-forward is capped at **1 restart per guild per hour**.

### Participant sub-state machine

Each enrolled participant tracks its own consent + capture state independently of other participants and of the session phase:

```
Enrolled → {
  Consent pending:   cache chunks to disk, await ConsentRecord
  Consent = Full:    flush disk cache to API → direct-to-API mode
  Consent = Decline: delete disk cache → drop pipeline
  Timeout (no response by session end): delete disk cache → drop pipeline
}
```

### Voice-state transitions (enrolment lifecycle)

Participant enrolment is triggered by voice-state events — not just by the initial `/record` scan. The bot auto-enrols anyone who enters the session's voice channel and treats leaving-while-pending as an implicit Decline. This covers three concrete flows that the pure `/record`-scan approach missed:

1. **Harness `/record`** spawns a session with empty participants. Feeders that join after session spawn need to be enrolled *on voice-join*, otherwise the sink has nowhere to route their decoded audio and every chunk is silently dropped.
2. **Slash `/record` late-joiners.** Someone who wasn't in the channel at `/record` time but connects mid-session is captured with pending-consent state, same as if they'd been present at `/record`.
3. **Pending user leaves.** If they bailed before consenting, waiting for their SSRC forever would stall the stabilization gate. Treat absence as implicit Decline (matches the `Pending → Decline` rule already codified for catastrophic-restart carry-forward).

Decision table (pure function `voice_state_transition`, unit-tested):

| Is bot? | User's new channel | Currently a participant? | Prior consent | Action |
|---|---|---|---|---|
| yes | any | any | any | Ignore (bot's own voice-state) |
| no | session channel | no | — | **EnrolAndTrack** (auto-register, mark present) |
| no | session channel | yes | any | TrackAsHuman (mark present; no re-enrol) |
| no | different / none | no | — | Drop (never was ours) |
| no | different / none | yes | Accepted / Declined | Drop (preserve consent; their audio so far is valid) |
| no | different / none | yes | Pending | **ImplicitDeclineAndDrop** (absent user = non-consent) |

Rejoin semantics: because SSRC→user_id mapping persists in the audio receiver across voice reconnect, and `packet_routes` is keyed by user_id, a user who leaves and comes back keeps the same per-participant task and cache. No data loss; no duplicate enrolment.

### Invariants (always hold)

1. **Ack within ~200 ms.** Every Discord interaction is ack'd (Defer/Acknowledge) as the first outbound call via the wrapper. Measured via `chronicle_interaction_ack_us`.
2. **One active session per guild.** Enforced by `DashMap::entry().or_insert_with()` atomic insert in `spawn_session`.
3. **Actor owns its Session.** No code outside the actor task mutates session state. External callers send `SessionCmd`s.
4. **Announcement plays at most once per session_id.** Gate opens exactly once per session; subsequent heal/reconnect events do not replay. A catastrophic restart spawns a *new* session_id, so its announcement is logically distinct.
5. **No chunk uploaded without a consent record.** The data-api side also enforces this; the bot will not attempt.
6. **Buffer dir is always cleaned up.** On any path out of the actor — normal finalize, cancel, panic, Stop, Restarting — the session's root buffer dir is removed. A supervisor in `main.rs` sweeps stale `$LOCAL_BUFFER_DIR/<session_id>/` dirs on startup for crashed-last-run remnants.
7. **No lock held across an `.await`.** Enforced by convention + `clippy::await_holding_lock`; the actor pattern makes this structural.

### Cancellation

Actor holds a `tokio_util::sync::CancellationToken`. The token is tripped by: `SessionCmd::Stop`, `SessionCmd::AutoStop`, `SessionCmd::Cancel`, or the global shutdown handler in `main.rs`. Long-running in-actor work (stabilization wait, DAVE retry sleeps, heal reconnect) polls the token via `tokio::select!` and exits cleanly.

### Error handling

Every per-participant task is spawned via `JoinSet`. If a task panics or returns `Err`, the `JoinSet` reports it; the actor logs + drops that participant's pipeline (their cached chunks are deleted) but keeps the session alive. Session-level failures (data-api unreachable past retry budget, songbird cannot join, repeated heal failures post-gate) trigger the Restarting path, not a silent exit.

### Observability contract

Log level per event:

| Event | Level |
|---|---|
| Session spawned, gate opened, Recording entered, Finalizing entered, actor exit, Restarting entered | `INFO` |
| Participant enrolled, consent recorded (scope=Full/Decline), license change | `INFO` |
| Heal fired, stabilization retry, chunk upload retry | `WARN` |
| Data API unreachable, voice join failed, actor panic, restart-budget exhausted | `ERROR` |
| Per-chunk upload success, per-voice-tick stats | `DEBUG` |

Tracing spans fan out:

```
session_actor{session_id, guild_id}
├── interaction{interaction_id, kind}           (spans detach on ack, handler runs concurrent)
├── participant_capture{pseudo_id}              (one per enrolled participant)
│     └── chunk_upload{seq}                     (during flush)
└── stabilization_gate                          (closes when gate opens)
```

### Scope fence (strict — additions require explicit Features entry)

The bot does **not**:

- Transcribe audio, run VAD, detect beats/scenes, or do any pipeline work. Those are `chronicle-pipeline` / `chronicle-worker`.
- Store audio or metadata directly in S3 or Postgres. Only through `chronicle-data-api`.
- Serve any user-facing UI beyond Discord messages + the harness. No web pages.
- Implement license mutation UI in Discord. Toggle UI lives in the portal.
- Handle bulk operations (list sessions, export, delete-on-request). Portal/data-api/admin surface.
- Host Whisper or any inference. Those are elsewhere.
- Manage its own Discord OAuth for humans. Portal's job.

Any feature addition must be added to the Features list above, with Interfaces + Behavior implications explicitly called out, before implementation.
