# Architecture

Cross-service data flow for the Chronicle stack. Each box is an independent repo deployed as its own container or binary. Post-features-pass shape: per-session actors in the bot, Operator-trait pipeline, ETag-guarded data-api, BFF-gated portal.

## One-paragraph summary

Discord voice flows into **chronicle-bot**, which runs one actor per session, writes per-speaker OPUS into a disk-backed cache, gates announcement + upload on a unanimous-consent stabilization window, then live-mixes a public combined stream. Chunks POST to **chronicle-data-api** — the single process that owns Postgres (24-hex pseudo_ids, ETag concurrency, audit log) and S3 (per-speaker + mixed audio). Data-api broadcasts `session_state_changed` / `chunk_uploaded` on an internal WebSocket bus. **chronicle-worker** subscribes, atomically claims sessions via state-machine PATCH, and feeds chunks into **chronicle-pipeline** (a Rust library: Operator trait chain, VAD → Whisper → metatalk filter → scene/beat detection, identical shape for streaming and one-shot). Outputs land back in data-api. **chronicle-portal** is a Next.js BFF + UI — the *only* internet-facing surface — serving Admin / GM / Player / Public views over the same data, enforcing per-user per-resource authorization before any data-api call. **chronicle-feeder** is a dev-only harness (fleet of Discord bots that play fixture audio) for end-to-end tests. No browser ever talks to data-api directly; no service except data-api touches Postgres or S3.

## High-level

```
Discord voice session
        │ DAVE E2EE (MLS)
        ▼
┌──────────────────────────────┐
│      chronicle-bot           │  Rust · serenity · songbird · opus2
│  (per-session actor model)   │  • /record → consent gate → capture
│                              │  • Disk-backed pre-consent cache
│                              │  • Stabilization + announcement
│                              │  • Live mix (license-flag aggregated)
│                              │  • Catastrophic recovery (same session_id)
└─────────────┬────────────────┘
              │ HTTP · Bearer token · shared-secret
              │ X-Capture-Started-At / X-Duration-Ms / X-Client-Chunk-Id
              ▼
┌──────────────────────────────────────────────┐
│          chronicle-data-api                  │  Rust · Axum · sqlx · aws-sdk-s3
│   (internal-only storage + event bus)        │  127.0.0.1:8001 (never public)
│                                              │
│  Postgres     sessions · participants        │  • 24-hex pseudo_ids
│               segments · beats · scenes      │  • user_display_names table
│               consent · mute_ranges          │  • ETag + If-Match concurrency
│               audit_log · user_display_names │  • bounded per-subscriber WS queue
│  S3           per-speaker OPUS · mixed OGG   │  • state-machine enforced transitions
│               pipeline outputs               │
│                                              │
│  WS bus       session_state_changed          │
│               chunk_uploaded                 │
│               segment_created  (future)      │
└──┬─────────────────────────────┬─────────────┘
   │                             │
   │ WS (services)               │ HTTP (services only)
   ▼                             ▼
┌──────────────────────────────┐   ┌──────────────────────────────┐
│      chronicle-worker        │   │      chronicle-portal        │
│  (event-driven · stateless)  │   │  (BFF + Next.js 15 / React)  │
│                              │   │                              │
│ • event_loop.rs select:      │   │ • ONLY internet-facing svc   │
│     ws · poll · retry-queue  │   │ • Discord OAuth (Auth.js v5) │
│ • session_runner per active  │   │ • Holds SHARED_SECRET        │
│ • atomic claim (state PATCH) │   │ • Per-request per-resource   │
│ • orphan reconciliation      │   │   authz on every BFF route   │
│ • retry: 30s / 2m / 10m      │   │ • SSE fan-out from data-api  │
│ • admin HTTP (env-gated)     │   │ • Strips privileged fields   │
│ • no circuit breaker         │   │   before client response     │
│                              │   │                              │
│          ▲                   │   │   Admin / GM / Player views  │
│          │ uses              │   │   over same codebase         │
│          ▼                   │   │                              │
│ ┌──────────────────────────┐ │   │ Behind Caddy TLS             │
│ │   chronicle-pipeline     │ │   └──────────────────────────────┘
│ │  (Rust library crate)    │ │
│ │                          │ │   ┌──────────────────────────────┐
│ │ Operator trait + chain:  │ │   │      chronicle-feeder        │
│ │  Resample → RMS → VAD    │ │   │   (dev harness · not prod)   │
│ │  → Whisper → metatalk    │ │   │                              │
│ │  → scenes → optional     │ │   │ • Fleet of Discord bots      │
│ │    beat/scene LLM        │ │   │   (Moe / Larry / Curly /     │
│ │                          │ │   │    Gygax) play fixture OGG   │
│ │ Same shape:              │ │   │ • Loopback control HTTP      │
│ │  streaming · one-shot    │ │   │ • E2E test orchestration     │
│ │  timescale-agnostic      │ │   │                              │
│ └──────────┬───────────────┘ │   └──────────────────────────────┘
└────────────┼─────────────────┘
             │ HTTP
             ▼
      Whisper HTTP API              Optional LLM endpoint
      (faster-whisper,              (scene / beat detection,
       OpenAI-compatible)           OpenAI-compatible)
```

## Repos — complete inventory

| Repo | Role | Language | Doc |
|---|---|---|---|
| `sessionhelper-hub` | Meta-repo: ARCHITECTURE, infra compose, cross-cutting docs, CLAUDE.md | Markdown + compose | This file |
| `chronicle-bot` | Discord voice capture bot | Rust (serenity + songbird-next) | `chronicle-bot/docs/architecture.md` |
| `chronicle-feeder` | E2E test Discord bots that play back audio files | Rust (serenity + songbird) | — (E2E test only) |
| `chronicle-portal` | Participant portal / transcript viewer | Next.js 15 / React 19 / TypeScript | `chronicle-portal/docs/architecture.md` |
| `chronicle-data-api` | Internal storage API — owns Postgres + S3 + event bus | Rust (Axum + sqlx + aws-sdk-s3) | — (no local arch doc) |
| `chronicle-worker` | Transcription worker, drives the pipeline | Rust (tokio + tungstenite) | — (no local arch doc) |
| `chronicle-pipeline` | Pure processing library: VAD → Whisper → operators | Rust library | `chronicle-pipeline/docs/architecture.md` |

The portal (`chronicle-portal`) is the only user-facing service and calls `chronicle-data-api`
directly through its own Next.js BFF (`src/app/api/*` routes) using the shared-secret auth.
There is no separate Rust public API gateway.

## Key architectural rules

1. **Only `chronicle-data-api` touches storage.** No other service imports `sqlx`,
   `aws-sdk-s3`, or opens files in the storage dirs. If a service needs data,
   it goes through an HTTP endpoint or a WebSocket subscription.
2. **Shared-secret service auth everywhere.** Internal services exchange the
   shared secret for a session token (POST `/internal/auth`). Tokens are bearer
   on HTTP and query-parameter on the WebSocket. Sessions are reaped after 90s
   without a heartbeat. See `CLAUDE.md` for the protocol.
3. **`chronicle-pipeline` is a pure library.** No I/O except the outbound Whisper /
   LLM HTTP calls. PCM `f32` samples in, `TranscriptSegment`s / `PipelineBeat`s /
   `PipelineScene`s out. The worker owns all orchestration.
4. **Consent-first capture.** The bot only records audio for users whose consent
   state is `Accept`. Mid-session joiners see a consent prompt and are added to
   the consented set only on accept.
5. **CC BY-SA 4.0 dataset.** All collected data is licensed under CC BY-SA 4.0
   with explicit per-participant opt-outs for LLM training and public release.
6. **Real-time by default, batch as fallback.** The worker drives transcription
   off WebSocket events (sub-second wake latency). Polling still exists as the
   catchup path for worker restarts and WS outages.

## Data flow — typical real-time session

1. **Collector** (`chronicle-bot`):
   - GM runs `/record` → bot posts consent embed, inserts session and
     participants via `POST /internal/sessions/{id}/participants/batch`.
   - Participants click Accept → quorum reached → bot joins voice.
   - DAVE handshake with retry. After `recording_started`, the collector spawns
     a three-tier DAVE heal task (initial OP5 timer check, periodic fallback,
     dead-connection fallback) that will leave/rejoin voice once if the MLS
     handshake is broken.
   - Per-speaker PCM streams through `VoiceTick` handler → lock-free mpsc →
     buffer task → **2 MB chunks** (~10.92s of s16le stereo 48 kHz) uploaded to
     `POST /internal/sessions/{id}/audio/{pseudo_id}/chunk`.
   - On `/stop` or auto-stop (empty channel, 30 s): flush all speaker buffers,
     upload `meta.json` + `consent.json`, `PATCH /internal/sessions/{id}` to
     status `uploaded`.

2. **Data API** (`chronicle-data-api`):
   - Stores chunks in S3 under `sessions/{session_id}/audio/{pseudo_id}/chunk_{seq:04}.pcm`.
   - Stores session + participant + segment + beat + scene + audit rows in Postgres.
   - After every successful mutation, broadcasts an `ApiEvent` on the internal
     tokio broadcast bus. Every authenticated WebSocket client gets the same
     delivery path: a per-connection drain task copies events from the broadcast
     bus into a private 1000-message mpsc queue that feeds the WS sender, so a
     slow client backpressures against its own queue rather than losing events.
     The data-api does not distinguish between client types — the internal/external
     boundary is the portal's concern, not this service's.

3. **Worker** (`chronicle-worker`):
   - Connects to `ws://data-api/ws?token=…`, subscribes to `sessions` topic.
   - On **`chunk_uploaded`**: downloads the chunk via
     `GET /internal/sessions/{id}/audio/{pseudo}/chunk/{seq}` (with retry on 5xx:
     1s / 2s / 4s), decodes s16le stereo → mono f32, looks up or creates an
     `ActiveSession`, calls `StreamingPipeline::feed_chunk(pseudo_id, samples)`,
     and posts any new segments back in 5-segment batches with 50 ms pacing for
     progressive frontend rendering.
   - On **`session_status_changed(status=uploaded)`**: finalizes the `ActiveSession`
     (flush remaining VAD state, run the operator chain, post beats/scenes,
     mark `transcribed`). If no `ActiveSession` exists (worker restart, missed
     events), falls through to the legacy batch path (`process_next_session`).
   - On WS disconnect: runs a catchup drain that calls
     `GET /internal/sessions?status=uploaded` and processes any stragglers
     before reconnecting with exponential backoff.

4. **Pipeline** (`chronicle-pipeline`) — called as a library by the worker:
   - Per-speaker resample to 16 kHz (Rubato).
   - RMS silence gate (cheap tier-1).
   - **`VadSession`** — stateful Silero VAD v6 carrying LSTM hidden/cell state
     across chunks so a single utterance that straddles a chunk boundary is
     still detected as one speech region.
   - Whisper transcription via HTTP (beam_size=5, temperature fallback
     [0.0, 0.2, 0.4], TTRPG `initial_prompt`).
   - Hallucination filtering: `avg_logprob < -0.4`, `no_speech_prob > 0.5`,
     `compression_ratio > 1.8`, plus frequency-based cross-speaker dedup.
   - Operator chain: `HallucinationOperator` → `MetatalkOperator` (IC/OOC tag)
     → `SceneOperator` (chunker, silence + max-duration) → optional LLM
     `BeatOperator` + `SceneOperator`.
   - Returns `PipelineResult { segments, beats, scenes, … }`.

5. **Frontend** (`chronicle-portal`):
   - Dashboard lists sessions.
   - Session page opens an SSE connection to `/api/events?session_id=…`, which
     the Next.js BFF bridges to the data-api WebSocket. `chunk_uploaded` events
     are filtered out (internal only); `session_status_changed`, `segment_added`,
     `segments_batch_added`, `beat_detected`, `scene_detected`, and
     `transcription_progress` are forwarded as SSE events.
   - Audio playback hook (`use-audio-playback`) fetches pre-mixed audio windows
     from `/api/sessions/{id}/audio?start=…&end=…&format=opus`, which the BFF
     proxies to `GET /internal/sessions/{id}/audio/mixed`. Three modes:
     `playSegment(start, end)` (exact range), `playFrom(time)` (continuous
     30 s windows with pre-fetch), and `seek(time)` (window-aware, reuses the
     current window when possible).

## Repo boundaries — what goes where

| Concern | Lives in |
|---|---|
| SQL schema, migrations | `chronicle-data-api/migrations/` |
| S3 bucket layout, paths, mixing helper | `chronicle-data-api/src/storage/`, `routes/audio_mix.rs` |
| Internal event bus, WebSocket dispatch | `chronicle-data-api/src/events.rs`, `routes/ws.rs` |
| Discord bot logic, slash commands, consent UI | `chronicle-bot/voice-capture/src/commands/` |
| Voice capture, SSRC→user mapping, DAVE heal | `chronicle-bot/voice-capture/src/voice/` + `commands/consent.rs::spawn_dave_heal_task` |
| Streaming pipeline (feed_chunk / finalize) | `chronicle-pipeline/src/streaming.rs` |
| Batch pipeline (process_session) | `chronicle-pipeline/src/pipeline.rs` |
| Audio processing (VAD, resample, Whisper client) | `chronicle-pipeline/src/{ad,audio,vad,transcribe}/` |
| Operator trait, hallucination / metatalk / scene / beat | `chronicle-pipeline/src/operators/` |
| Worker WS event loop, ActiveSession, chunk handling | `chronicle-worker/src/worker.rs` |
| Worker API client + chunk retry/backoff | `chronicle-worker/src/api_client.rs` |
| Frontend BFF (server-side data-api client + SSE bridge) | `chronicle-portal/src/lib/data-api.ts`, `src/app/api/*` |
| Frontend audio playback (window fetch + continuous mode) | `chronicle-portal/src/hooks/use-audio-playback.ts` |
| Cross-service env vars, shared secret | This hub (`CLAUDE.md`) |

## Audio format — cross-cutting invariant

All audio chunks on the wire and in S3 are:

- **Raw PCM, signed 16-bit little-endian, stereo, 48 kHz**
- **2 MB per chunk** (~10.92 seconds of audio)
- Uploaded by the collector as one chunk per speaker
- Stored under `sessions/{session_id}/audio/{pseudo_id}/chunk_{seq:04}.pcm`
- Downloaded by the worker per-chunk (WS event-driven) or all-at-once (batch fallback)
- Decoded to mono f32 at the worker edge; pipeline resamples to 16 kHz internally
- Mixed on demand by `GET /internal/sessions/{id}/audio/mixed` for the frontend
  (WAV output; Opus encoding is a TODO that currently falls back to WAV)

## Deployment

- **Dev VPS** — Hetzner Cloud instance running the full OVP compose stack
  (postgres + data-api + collector + worker + pipeline LLMs + feeders) from
  `/opt/ovp/` on the dev host. Dev Discord bot and dev feeder bots.
- **Prod VPS** — Hetzner Cloud instance running the same compose stack, with
  images pulled from `ghcr.io/sessionhelper/<service>:<tag>` on each release.
  Prod Discord bot.
- **Object Storage** — Hetzner Object Storage (Nuremberg). Two buckets: one
  prod, one dev.

Specific host addresses, SSH users, and `pass` credential entries live in the
maintainer's local-only companion repo; see `infra/README.md`.
