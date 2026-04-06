# Architecture

Cross-service data flow for the Session Helper / Open Voice Project stack. Each box is an independent repo deployed as its own container or binary.

## High-level

```
Discord voice session
        │
        ▼
┌────────────────────┐
│  ttrpg-collector   │  Rust + serenity + songbird (DAVE E2EE)
│  (Discord bot)     │  • /record → consent → capture per-user PCM
└─────────┬──────────┘  • Uploads 5MB audio chunks to Data API
          │
          │ HTTP (Bearer token)
          ▼
┌────────────────────┐
│   ovp-data-api     │  Rust + Axum, 127.0.0.1:8001 only
│   (storage API)    │  • Owns Postgres (sessions, participants, segments, consent)
└─┬─────────────────┬┘  • Owns S3 (audio chunks, metadata files)
  │                 │   • Shared-secret auth + session tokens
  │                 │
  │ (Postgres)      │ (Hetzner Object Storage, S3-compatible)
  ▼                 ▼

┌────────────────────┐           ┌──────────────────────┐
│    ovp-worker      │──────────►│  External services   │
│  (batch poller)    │           │  • Whisper HTTP API  │
│                    │           │  • Optional LLM      │
│  1. poll for       │           │    (scene detection) │
│     "uploaded"     │           └──────────────────────┘
│  2. download chunks│
│  3. run pipeline  ─┼──uses──►  ┌──────────────────────┐
│  4. post segments  │           │   ovp-pipeline       │
│                    │           │   (Rust library)     │
│                    │           │  RMS → VAD → Whisper │
│                    │           │  → hallucination     │
│                    │           │    filter → scenes   │
│                    │           │  → beats → segments  │
│                    │           └──────────────────────┘
└────────────────────┘

┌──────────────────────────┐
│ ttrpg-collector-frontend │  Next.js / TypeScript
│ (participant portal)     │  • Discord OAuth login
│                          │  • Review sessions, edit transcripts
│                          │  • Manage consent, data export
└─────────────┬────────────┘
              │
              │ HTTP (Bearer from Data API auth)
              ▼
         ovp-data-api
```

## Key architectural rules

1. **Only `ovp-data-api` touches storage.** No other service imports `sqlx`, `aws-sdk-s3`, or opens files in the storage dirs. If a service needs data, it goes through an HTTP endpoint.
2. **Shared-secret service auth everywhere.** See `CLAUDE.md` for the protocol. No file-based tokens.
3. **`ovp-pipeline` is a pure library.** No I/O except the outbound Whisper HTTP call. PCM `f32` samples in, `TranscriptSegment`s out. The worker owns all orchestration.
4. **Consent-first capture.** The bot only records audio for users whose consent state is `Accept`. Mid-session joiners see a consent prompt and are added to the consented set only on accept.
5. **CC BY-SA 4.0 dataset.** All collected data is licensed under CC BY-SA 4.0 with explicit per-participant opt-outs for LLM training and public release.

## Data flow — typical session

1. **Collector** (`ttrpg-collector`):
   - User runs `/record` → bot posts consent embed
   - Participants click Accept → quorum reached → bot joins voice
   - Per-speaker PCM streams through `VoiceTick` handler → buffered → 5MB chunks uploaded to Data API
   - On `/stop` or auto-stop (empty channel, 30s): finalize session, upload `meta.json` + `consent.json`, mark session `uploaded` in DB

2. **Data API** (`ovp-data-api`):
   - Stores chunks in S3 under `sessions/{session_id}/audio/{pseudo_id}/chunk_{seq:04}.pcm`
   - Stores session + participant + consent state in Postgres
   - Updates session status: `recording` → `uploaded`

3. **Worker** (`ovp-worker`):
   - Polls `GET /internal/sessions?status=uploaded` every 10s
   - For each session: list participants (filter to `consent_scope=full`), download all chunks per speaker, decode stereo s16le → mono f32
   - Call `ovp_pipeline::process_session()` with VAD + Whisper config
   - Post resulting segments back via `POST /internal/sessions/{id}/segments`
   - Update status: `uploaded` → `transcribing` → `transcribed`

4. **Pipeline** (`ovp-pipeline`) — called as a library by the worker:
   - Resample to 16kHz (Rubato)
   - RMS silence gate (cheap tier-1)
   - Silero VAD v6 via ONNX (tier-2)
   - Whisper transcription via HTTP
   - Hallucination filter (frequency-based, cross-speaker dedup)
   - Scene chunker → scene operator (optional LLM) → beat operator
   - Return `PipelineResult { segments, excluded, scenes_detected, … }`

5. **Frontend** (`ttrpg-collector-frontend`):
   - Participant logs in via Discord OAuth
   - Dashboard lists their sessions, status, consent state
   - Session detail: transcript viewer with per-segment playback, inline editing, flagging
   - Settings: global opt-out, data export, account deletion

## Repo boundaries — what goes where

| Concern | Lives in |
|---|---|
| SQL schema, migrations | `ovp-data-api/migrations/` |
| S3 bucket layout, paths | `ovp-data-api/src/storage/` |
| Discord bot logic, slash commands, consent UI | `ttrpg-collector/voice-capture/src/commands/` |
| Voice capture, SSRC→user mapping | `ttrpg-collector/voice-capture/src/voice/` |
| Audio processing (VAD, resample, Whisper client) | `ovp-pipeline/src/` |
| Operator trait, scene/beat detection | `ovp-pipeline/src/operators/` |
| Worker polling, batch orchestration | `ovp-worker/src/worker.rs` |
| Frontend API client, auth | `ttrpg-collector-frontend/src/lib/api-client.ts` |
| Cross-service env vars, shared secret | This hub (`CLAUDE.md`) |

## Deployment

- **Dev VPS** — Hetzner Cloud instance running the full OVP compose stack (postgres + data-api + collector) from a local docker-compose file at `/opt/ovp/`. Dev Discord bot.
- **Prod VPS** — Hetzner Cloud instance running the same compose stack, with images pulled from `ghcr.io/sessionhelper/<service>:<tag>` on each release. Prod Discord bot.
- **Object Storage** — Hetzner Object Storage (Nuremberg). Two buckets: one prod, one dev.

Specific host addresses, SSH users, and `pass` credential entries live in the maintainer's local-only companion repo; see `infra/README.md`.
