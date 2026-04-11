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
│    ├─ Inserts SSRCs into ssrcs_seen on every tick    │
│    │  (heal-task read path, cleared on heal rejoin)  │
│    └─ Sends AudioPackets via mpsc channel            │
│                                                      │
│  Buffer Task (voice/receiver.rs)                     │
│    ├─ Per-speaker buffers (keyed by SSRC)            │
│    ├─ bytemuck cast i16 → bytes (zero-copy)          │
│    ├─ 2MB chunk threshold (R5)                       │
│    └─ Upload via Data API HTTP                       │
│                                                      │
│  DAVE Health Monitor (commands/consent.rs)           │
│    Three tiers all running inside spawn_dave_heal_task │
│                                                      │
│    1. Initial check — 10s OP5 timer window           │
│         SpeakingTracker emits OP5 events to op5_rx    │
│         For each OP5 user, wait up to 10s for their   │
│         SSRC to appear in ssrcs_seen. If SSRCs are    │
│         seen but only a subset are mapped, trigger    │
│         the heal immediately.                        │
│                                                      │
│    2. Periodic fallback — every 10s after stable     │
│         Re-check op5_rx, check mapped < consented    │
│         whenever SSRCs are coming in.                │
│                                                      │
│    3. Dead-connection fallback                       │
│         If recording_stable but ssrcs_seen stays     │
│         empty for 30s, the connection is dead →      │
│         trigger heal.                                │
│                                                      │
│    Heal path (R3): leave → 2s → rejoin same channel  │
│         → reattach receiver with a fresh op5 channel │
│         → clear ssrcs_seen → replay start announce   │
│                                                      │
│  recording_stable (session.rs)                       │
│    AtomicBool flipped once the initial DAVE check    │
│    passes or a heal completes. Exposed via the       │
│    harness /status endpoint so E2E tests know when   │
│    feeders can safely start transmitting.            │
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
          │
          └── broadcasts ChunkUploaded event over the
              internal event bus → worker wakes up via
              WebSocket and begins streaming transcription
```

## Component verification checklist

### 1. SSRC-to-user mapping

**File:** `voice/receiver.rs` — `SpeakingTracker`

| Check | Status |
|---|---|
| SpeakingStateUpdate handler maps SSRC → user_id | ✅ Exists |
| ssrc_to_user is Arc<StdMutex<HashMap>> shared with AudioReceiver | ✅ Exists |
| Unmapped SSRCs in VoiceTick are logged (diagnostic) | ✅ |
| Unmapped SSRCs still trigger audio_received (DAVE check) | ✅ |
| Every VoiceTick inserts the SSRC into `ssrcs_seen` | ✅ |

**Known gap:** SpeakingStateUpdate (OP5) is edge-triggered. If a bot
was already speaking when the collector joined, the OP5 was missed
and the SSRC is never mapped. The "SSRCs in VoiceTick but unmapped"
branch of the heal task now catches this case — if `ssrcs_seen.len() > 0`
and `mapped < consented`, the heal fires even without an OP5 event
and the fresh join gets a new batch of OP5 events.

### 2. DAVE health detection (R2)

**Files:** `voice/receiver.rs` — `SpeakingTracker` + `AudioReceiver`,
`commands/consent.rs` — `spawn_dave_heal_task()`

| Check | Status |
|---|---|
| OP5-triggered detection (not amplitude-based) | ✅ Implemented |
| SpeakingTracker sends OP5 events to heal system via `op5_tx` | ✅ |
| VoiceTick inserts decoded SSRC into `ssrcs_seen` | ✅ |
| **10-second** initial OP5 timer (one per OP5 speaker) | ✅ |
| Initial check also uses the `ssrcs_seen` vs `consented_count` comparison so unmapped SSRCs still trigger a heal | ✅ |
| Periodic fallback tick (every 10s after stable) re-checks `consented_count` live | ✅ |
| Dead-connection fallback: 30s with no SSRCs seen → heal | ✅ |
| Timer cancelled when SSRC appears | ✅ |
| Muted/PTT users don't trigger (no OP5 = no timer) | ✅ structural |
| Single-attempt heal (no retry loop) | ✅ |
| No amplitude thresholds or voice_state lookups | ✅ |

### 3. Self-healing reconnect (R3)

**File:** `commands/consent.rs` — `spawn_dave_heal_task()` (heal path)

| Check | Status |
|---|---|
| Leave voice on DAVE failure | ✅ |
| 2-second wait before rejoin | ✅ |
| Rejoin same channel | ✅ |
| Reattach audio receiver on new Call, with a fresh `op5_tx`/`op5_rx` | ✅ (`Session::reattach_audio_receiver`) |
| Clear `ssrcs_seen` so the heal check restarts clean | ✅ |
| Replay start announcement | ✅ |
| Flip `recording_stable` once heal completes | ✅ |
| Log dave_heal_triggered / dave_heal_complete | ✅ |
| Works in both slash-command and harness paths | ✅ Both spawn the task |

### 4. Consent gating

**File:** `voice/receiver.rs` — `AudioReceiver::act()`

| Check | Status |
|---|---|
| Only capture audio for users in consented_users set | ✅ |
| consented_users updated on mid-session accept | ✅ |
| Bypass users added to consented_users | ✅ |
| Bot users pass the bot filter when on bypass list | ✅ |

### 5. Chunked upload (R5)

**File:** `voice/receiver.rs` — `buffer_task()` + `SpeakerBuffer`

| Check | Status |
|---|---|
| Per-speaker buffer accumulates bytes | ✅ |
| `CHUNK_SIZE = 2 * 1024 * 1024` (2 MB) | ✅ |
| Flush at chunk threshold | ✅ |
| Final flush on session end (partial chunk) | ✅ |
| Upload via Data API | ✅ |
| Upload retry on transient failures (R7) | ✅ `upload_chunk_with_retry` — 1s/2s/4s backoff on 5xx/network, re-auth on 401, fail-fast on 4xx |

### 6. Session lifecycle

**File:** `session.rs`, `commands/record.rs`, `commands/consent.rs`,
`commands/stop.rs`

| Check | Status |
|---|---|
| Session created on /record | ✅ |
| Participants registered via `add_participants_batch` | ✅ (single round trip) |
| Consent collected via buttons or bypass | ✅ |
| Recording starts on quorum met | ✅ |
| DAVE retry loop (3 attempts) | ✅ |
| DAVE heal task spawned after recording_started | ✅ |
| `recording_stable` flag flipped on success; read via harness /status | ✅ |
| /stop finalizes and uploads remaining chunks | ✅ |
| Auto-stop on empty channel (30s) | ✅ |
| Auto-stop counts bypass users | ✅ |

## Action items

1. ~~**R2 fix:** Replace amplitude-based DAVE check with OP5-triggered detection.~~ ✅
2. ~~**R5 fix:** Change chunk size from 5MB to 2MB.~~ ✅ 2 MB is live.
3. ~~**Worker retry on S3 errors:** per-chunk retry with backoff.~~ ✅
   Worker uses `download_chunk_with_retry` (1s/2s/4s backoff on 5xx), and the
   batch path now skips failed chunks instead of failing the whole session.
4. ~~**Collector-side R7:** Add retry (3 attempts, 1s backoff) to the chunk
   upload in the buffer task.~~ ✅ `upload_chunk_with_retry` mirrors the
   worker's `download_chunk_with_retry`: 1s/2s/4s backoff on 5xx and
   network errors, re-auth on 401, fail-fast on other 4xx. Spawned so
   retries don't back-pressure the mpsc receiver loop.
5. **Upstream PR:** File a bug/PR on songbird-next for the MLS proposal
   clearing race in `ws.rs`. Include the root cause analysis and a proposed
   fix (queue proposals instead of clearing pending commits).
