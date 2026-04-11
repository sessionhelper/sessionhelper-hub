# Voice Capture Architecture

Concrete implementation of the voice capture system. Each section
maps to a requirement in `voice-capture-requirements.md`.

## System overview

```
Discord Voice Channel
  │
  │  Per-user Opus/RTP streams (DAVE E2EE encrypted)
  ▼
┌─────────────────────────────────────────────────────┐
│ Collector (chronicle-bot)                          │
│                                                      │
│  Songbird driver (voice WebSocket + UDP RX)          │
│    │                                                 │
│    ├─ DAVE/MLS key exchange (davey crate)            │
│    │    └─ Per-user decryptors in DaveSession        │
│    │                                                 │
│    ├─ RTP decrypt → Opus decode → VoiceTick events   │
│    │    └─ Per-SSRC decoded i16 PCM (48kHz stereo)   │
│    │                                                 │
│    └─ SpeakingStateUpdate (OP5) → SSRC-to-user map   │
│                                                      │
│  AudioReceiver (voice/receiver.rs)                   │
│    ├─ Filters by consented_users set                 │
│    ├─ Maps SSRC → pseudo_id via ssrc_to_user         │
│    ├─ Tracks speakers_with_audio per user (R2)       │
│    ├─ Sends AudioPackets via mpsc channel            │
│    └─ audio_received flag (DAVE confirmation)        │
│                                                      │
│  Buffer Task (voice/receiver.rs)                     │
│    ├─ Per-speaker buffers (keyed by SSRC)            │
│    ├─ bytemuck cast i16 → bytes (zero-copy)          │
│    ├─ 2MB chunk threshold (R5)                       │
│    └─ Upload via Data API HTTP                       │
│                                                      │
│  DAVE Health Monitor (voice/receiver.rs + consent.rs) │
│    ├─ OP5-triggered: SpeakingTracker fires event     │
│    ├─ 2-second timer per OP5 speaker                 │
│    ├─ Cancel timer when SSRC appears in VoiceTick    │
│    ├─ Timer expires → DAVE broken → trigger heal     │
│    ├─ Muted/PTT users: no OP5 → no timer → safe     │
│    ├─ If broken: leave → 2s → rejoin → reattach (R3) │
│    ├─ Replay start announcement on heal              │
│    └─ One attempt only                               │
│                                                      │
│  Session State Machine (session.rs)                  │
│    AwaitingConsent → StartingRecording → Recording    │
│    → Finalizing → Complete                           │
│                                                      │
└─────────────────────────────────────────────────────┘
          │
          │  POST /internal/sessions/{id}/audio/{pseudo}/chunk
          │  (2MB raw s16le stereo PCM)
          ▼
     Data API → S3
```

## Component verification checklist

### 1. SSRC-to-user mapping

**File:** `voice/receiver.rs` — `SpeakingTracker`

| Check | Status |
|---|---|
| SpeakingStateUpdate handler maps SSRC → user_id | ✅ Exists |
| ssrc_to_user is Arc<StdMutex<HashMap>> shared with AudioReceiver | ✅ Exists |
| Unmapped SSRCs in VoiceTick are logged (diagnostic) | ✅ v0.5.6 diagnostic |
| Unmapped SSRCs still trigger audio_received (DAVE check) | ✅ v0.5.7 fix |

**Known gap:** SpeakingStateUpdate (OP5) is edge-triggered. If a bot
was already speaking when the collector joined, the OP5 was missed
and the SSRC is never mapped. The feeder silence loop mitigates this
for E2E tests. For production, the R3 heal reconnect is the fallback
— the fresh join gets a new batch of OP5 events.

### 2. DAVE health detection (R2)

**Files:** `voice/receiver.rs` — `SpeakingTracker` + `AudioReceiver`, `commands/consent.rs` — `spawn_dave_heal_task()`

| Check | Status |
|---|---|
| OP5-triggered detection (not amplitude-based) | ✅ Implemented |
| SpeakingTracker sends OP5 events to heal system | ✅ via op5_tx channel |
| VoiceTick sets ssrcs_seen on decoded audio | ✅ per-tick HashSet insert |
| 2-second timer per OP5 speaker | ✅ in heal task |
| Timer cancelled when SSRC appears | ✅ heal task checks ssrcs_seen |
| Muted/PTT users don't trigger (no OP5 = no timer) | ✅ structural |
| Single-attempt heal (no retry loop) | ✅ Exists |
| No amplitude thresholds or voice_state lookups | ✅ Removed |

### 3. Self-healing reconnect (R3)

**File:** `commands/consent.rs` — `spawn_dave_heal_task()`

| Check | Status |
|---|---|
| Leave voice on DAVE failure | ✅ Exists |
| 2-second wait before rejoin | ✅ Exists |
| Rejoin same channel | ✅ Exists |
| Reattach audio receiver on new Call | ✅ Exists |
| Replay start announcement | ✅ Exists |
| Log dave_heal_triggered / dave_heal_complete | ✅ Exists |
| Works in both slash-command and harness paths | ✅ Both spawn the task |

### 4. Consent gating

**File:** `voice/receiver.rs` — `AudioReceiver::act()`

| Check | Status |
|---|---|
| Only capture audio for users in consented_users set | ✅ Exists |
| consented_users updated on mid-session accept | ✅ Exists |
| Bypass users added to consented_users | ✅ v0.5.1 |
| Bot users pass the bot filter when on bypass list | ✅ v0.5.2 |

### 5. Chunked upload (R5)

**File:** `voice/receiver.rs` — `buffer_task()`

| Check | Status |
|---|---|
| Per-speaker buffer accumulates bytes | ✅ Exists |
| Flushes at chunk threshold | ✅ Exists (currently 5MB) |
| Chunk threshold should be 2MB | ❌ Not yet updated |
| Final flush on session end (partial chunk) | ✅ Exists |
| Upload via Data API with retry | ⚠️ Single attempt, no retry |

**Action needed:** Change `CHUNK_SIZE` from 5MB to 2MB. Add retry
on upload failure (R6).

### 6. Session lifecycle

**File:** `session.rs`, `commands/record.rs`, `commands/stop.rs`

| Check | Status |
|---|---|
| Session created on /record | ✅ |
| Consent collected via buttons or bypass | ✅ |
| Recording starts on quorum met | ✅ |
| DAVE retry loop (3 attempts) | ✅ |
| DAVE heal task spawned after recording_started | ✅ v0.6.0 |
| /stop finalizes and uploads remaining chunks | ✅ |
| Auto-stop on empty channel (30s) | ✅ |
| Auto-stop counts bypass users | ✅ v0.5.8 |

## Action items

1. ~~**R2 fix:** Replace amplitude-based DAVE check with OP5-triggered
   detection.~~ ✅ Done — SpeakingTracker sends OP5 events, heal task
   uses 2s timer + ssrcs_seen check.

2. **R5 fix:** Change chunk size from 5MB to 2MB in the buffer task's
   `CHUNK_SIZE` constant.

3. **R7 fix:** Add retry (3 attempts, 1s backoff) to chunk upload in
   the buffer task.

4. **Upstream PR:** File a bug/PR on songbird-next for the MLS
   proposal clearing race in `ws.rs`. Include the root cause analysis
   and a proposed fix (queue proposals instead of clearing pending
   commits).

5. **Worker retry on S3 errors:** Worker currently fails the whole
   session on a transient S3 download error (500 from data-api).
   Needs per-chunk retry with backoff, and session-level retry
   (reset to `uploaded` after N failures so it gets re-polled).
