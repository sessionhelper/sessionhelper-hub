# Architecture audit — 2026-04-10

Full module-by-module audit of the Session Helper / OVP codebase against
the architecture documentation. Scope covered:

- `sessionhelper-hub/ARCHITECTURE.md`
- `sessionhelper-hub/docs/voice-capture-architecture.md`
- `sessionhelper-hub/docs/voice-capture-requirements.md`
- `chronicle-bot/docs/architecture.md`
- `chronicle-pipeline/docs/architecture.md`
- `chronicle-portal/docs/architecture.md`
- source code of `chronicle-data-api`, `chronicle-worker`, `chronicle-api`, `chronicle-feeder`
  (no local arch docs; audited against the top-level doc's descriptions)

## Summary of drift

### sessionhelper-hub/ARCHITECTURE.md
Severity: large — doc described the old poll-based worker and
5 MB chunks with no mention of the WebSocket event bus.

| Out-of-date claim | Reality |
|---|---|
| Worker "polls `GET /internal/sessions?status=uploaded` every 10s" | Worker is WS-event-driven (`worker.rs::handle_ws_event`). Polling is now only a catchup path on disconnect. |
| "5MB audio chunks" | Chunks are 2 MB (~10.92 s); both collector (`CHUNK_SIZE`) and data-api mixer constant agree. |
| ASCII diagram showed worker on the left of pipeline, no WS feedback loop | Updated to show WS fanout to worker + frontend. |
| Repo inventory missing chronicle-worker, chronicle-feeder, chronicle-api, frontend as peers | Added a full-inventory table. |
| No mention of the data-api event bus, `ActiveSession`, streaming pipeline, or Whisper tuning | Added a data-flow section describing the real-time path. |
| Frontend section implied direct data-api hits from the browser | Described the BFF + SSE bridge model. |

**Updated:** yes — ARCHITECTURE.md was largely rewritten but preserved
the "key architectural rules" block.

### sessionhelper-hub/docs/voice-capture-architecture.md
Severity: moderate — core narrative was right but the DAVE heal and
chunk-size sections were outdated.

| Out-of-date claim | Reality |
|---|---|
| "2-second OP5 timer" | 10-second initial window. |
| Single-tier OP5 heal | Three-tier heal: initial OP5 window + periodic fallback + dead-connection fallback (`commands/consent.rs::spawn_dave_heal_task`). |
| "Chunk threshold should be 2MB — ❌ Not yet updated" | 2 MB is live. |
| "Worker retry on S3 errors" marked as action item | Done — `download_chunk_with_retry` with 1s/2s/4s backoff + session-level partial-failure tolerance. |
| `ssrcs_seen` clear-on-heal not documented | Added to the "Reattach" checklist. |
| `recording_stable` atomic + harness /status exposure not documented | Added. |

**Updated:** yes — rewrote the diagram and the verification tables.

### sessionhelper-hub/docs/voice-capture-requirements.md
Severity: minor — the requirement text was right, but the R2 detection
snippet still said "2-second timer".

**Updated:** yes — replaced the R2 detection pseudocode to show the
three-tier layout. Rest of the doc preserved.

### chronicle-bot/docs/architecture.md
Severity: moderate — missing the DAVE three-tier heal, `recording_stable`,
batch participant insert, and the 2 MB chunk update.

| Out-of-date claim | Reality |
|---|---|
| "When buffer >= 5MB" | 2 MB. |
| DAVE handshake → single retry loop; no heal task described | Three-tier heal task documented. |
| `/record` participant insertion loop | `add_participants_batch` single round trip. |
| No `recording_stable` / harness /status mention | Added. |

**Updated:** yes.

### chronicle-pipeline/docs/architecture.md
Severity: moderate — missing streaming pipeline, `VadSession`,
`MetatalkOperator`, Whisper hallucination config fields, and the
`operators_with_llm_scene()` chain.

| Out-of-date claim | Reality |
|---|---|
| `TranscriberConfig` shown with just endpoint/model/language | Real config has `initial_prompt`, `beam_size`, `temperature`, `hallucination_logprob_threshold`, `hallucination_no_speech_threshold`, `hallucination_compression_ratio`. |
| Only batch `process_session` documented | `StreamingPipeline::{new, feed_chunk, finalize}` is the real-time path used by the worker. |
| "Crate ships four operators" — hallucination, scene_chunker, scene, beat | Crate ships five: add `MetatalkOperator` (rule-based IC/OOC classifier). Default chain is hallucination → metatalk → scene_chunker. |
| `vad/mod.rs` described as stateless only | Adds stateful `VadSession::{feed, flush}` carrying Silero LSTM state across streaming chunks. |
| No note on which operators emit structural output via `collect_scenes`/`collect_beats` | Clarified: only the LLM-backed `scene.rs` and `beat.rs` produce rows. The mechanical `scene_chunker.rs` only tags segments with `chunk_group` and does not implement `collect_scenes()`. |

**Updated:** yes — targeted edits to the existing sections rather than
a full rewrite. The "planned" sections (correction history,
back-propagation, event buffers, lore reconciliation) were kept as
written because they're still accurately labelled "planned".

> **Drift to flag:** the audit prompt noted "Scene chunker properly
> implements collect_scenes() now" as a recent change. Verification
> against `src/operators/scene_chunker.rs` shows that **it does not
> override `collect_scenes()`**; only `src/operators/scene.rs` (the
> LLM-backed scene op) does. The doc was updated to reflect the actual
> code rather than the prompt's claim. This might be a case where the
> intended change was not merged, or where the prompt conflated the two
> scene operators. Worth confirming with the maintainer.

### chronicle-portal/docs/architecture.md
Severity: large — the doc described a completely different deployment
(Caddy + Rust Axum public API + MSW / Playwright test strategy) that no
longer matches the code on disk.

| Out-of-date claim | Reality |
|---|---|
| Caddy → Rust Axum `/api/*` + Next.js | No Caddy or Rust API in the current stack. Next.js BFF talks directly to `chronicle-data-api` via `src/lib/data-api.ts`. |
| `/api/v1/auth/*` Axum routes table | That was `chronicle-api`'s surface; it's dormant. Auth is planned via Auth.js v5 in Next.js per the hub's `auth-proxy-plan.md`. |
| SQL schema listed in the frontend doc | Schema lives in `chronicle-data-api/migrations/`. Frontend now just mirrors data-api response types. |
| No mention of SSE bridge, windowed audio fetch, BFF proxy | Documented: `src/app/api/events/route.ts` (SSE bridge with `chunk_uploaded` filter) and `src/app/api/sessions/[id]/audio/route.ts` (proxy to `/audio/mixed`). |
| "Discord bot writes to Postgres at 5 points" | Bot writes go through the data-api HTTP API — the frontend doc shouldn't be describing the bot's DB schema anyway. Removed. |

**Updated:** yes — rewritten to describe the real Next.js BFF + SSE
bridge + windowed audio model.

## Repos without local architecture docs

The following repos have no `docs/architecture.md` of their own. Their
behaviour is documented in the top-level `ARCHITECTURE.md`, which has
been updated to reflect current reality. No new doc files were created
for them (per the audit instructions).

- **`chronicle-data-api/`** — Rust / Axum storage API. Worth a future doc
  covering:
  - module layout (`auth`, `routes`, `db`, `storage`, `events`)
  - the event bus (`events.rs`) and how subscriber types route between
    `mpsc` (internal) and `broadcast` (external)
  - the `ParticipantWithUser` join shape
  - the mixed-audio route's sample-byte math
- **`chronicle-worker/`** — Worker event loop. Worth a future doc covering:
  - `ActiveSession` lifecycle (per-session streaming state)
  - WS connect / subscribe / catchup / backoff flow
  - `process_next_session` batch fallback
  - `PipelineRunner` trait and the test swap story
- **`chronicle-api/`** — **Dormant public gateway**. The frontend no longer
  uses it. It still compiles and exposes a `/api/v1/*` route set
  (`auth`, `sessions`, `transcript`, `beats`, `scenes`) but nothing in
  the compose stacks wires it. The hub's `auth-proxy-plan.md` describes
  the deprecation. Recommend either reviving it as a third-party public
  API or archiving the repo.
- **`chronicle-feeder/`** — E2E test harness only. Dev-only
  Discord bot that plays back WAV files to simulate participants.
  Single `main.rs` — a local architecture doc is not warranted.

## Concerning drift / mismatches between docs and code

1. **Scene chunker `collect_scenes()`.** Audit prompt said it was added;
   source shows it is not. See note in the pipeline section above.
2. **Collector-side upload retry (R7).** `voice-capture-requirements.md`
   still requires 3-attempt backoff on chunk upload, and that is still
   not implemented on the collector. Worker-side retry was added but
   only on the download path; a data-api outage during a live session
   will still drop chunks. Logged as an action item in
   `voice-capture-architecture.md`.
3. **Frontend participant metadata (title / display_name / character_name).**
   The data-api exposes these fields and has the `PATCH /internal/participants/{id}`
   endpoint to set them, but the transcript viewer in
   `src/app/sessions/[id]/page.tsx` does not render them yet. Not a
   regression — just a gap between "schema supports it" and "UI uses it".
4. **Auth gating.** Frontend has no login gate; the portal relies on
   deployment locking (127.0.0.1-only dev) instead. `auth-proxy-plan.md`
   describes the intended Auth.js v5 path. Documented in the frontend
   arch doc as "status: WIP".
5. **`chronicle-api` dormancy.** Worth an explicit decision — either wire it
   as a public third-party API or archive the repo. The code still
   builds and the auth middleware still works, which makes it easy to
   forget it's unused.

## Doc updates pushed

Commits are left uncommitted on the `dev` branch of each affected repo.
Per the audit instructions the doc updates are ready to commit and push;
no git activity was performed as part of this audit.

Files touched:

- `sessionhelper-hub/ARCHITECTURE.md`
- `sessionhelper-hub/docs/voice-capture-architecture.md`
- `sessionhelper-hub/docs/voice-capture-requirements.md`
- `chronicle-bot/docs/architecture.md`
- `chronicle-pipeline/docs/architecture.md`
- `chronicle-portal/docs/architecture.md`
- `sessionhelper-hub/docs/arch-audit-2026-04-10.md` (this report)
