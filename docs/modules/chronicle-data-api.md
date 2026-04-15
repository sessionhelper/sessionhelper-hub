# chronicle-data-api

Internal application bus for the Chronicle service family. Single source of truth for session storage — the only service that touches Postgres and the S3-compatible object store directly. Strictly internal: never faces the public internet. All access via shared-secret authentication. Production clients are `chronicle-bot`, `chronicle-worker`, and future `chronicle-portal` BFF.

Status: **Features locked. Interfaces and Behavior pending.** Implementation at `/home/alex/sessionhelper/chronicle-data-api/`.

---

## Features

1. **Service authentication.** Shared secret per deployment (`SHARED_SECRET`). Clients POST `/internal/auth` with `{ shared_secret, service_name }` and receive a session token. All mutating endpoints require `Authorization: Bearer <token>`. Heartbeat every <90s via `/internal/heartbeat` keeps the server-side session row alive. No scopes, no read-only tokens — every authenticated service has full internal access. Rotation: on incident only.

2. **Session lifecycle with recovery.** Sessions represent TTRPG sessions and outlive individual recording attempts. State machine:

    ```
    recording ──finalize──> uploaded ──claim──> transcribing ──> transcribed
       │                                             │
       │                                             └── error ──> transcribing_failed ──retry──> transcribing
       │
       └── catastrophic (no in-process recovery) OR manual discard ──> abandoned
                                                  │
                                                  └── resume (within RESUME_TTL, default 24h) ──> recording
    ```

    Server enforces valid transitions; illegal transitions return 409. `abandoned` can be revived via `POST /internal/sessions/{id}/resume` within `RESUME_TTL`. Sessions are created by the bot only at consent-gate-open; pre-gate aborts never produce a row. Auto-restart from within an active session does not create a new session_id — it continues under the existing one. `deleted` is a terminal tombstone state invoked by any authenticated service; cascades removal of chunks + pipeline outputs + metadata.

3. **Participant + user management.** Upsert users by pseudo_id. Add participants to sessions individually or in batch. Mid-session joiners supported. Opt-out is per-session via the `Decline` consent scope — fresh consent required for every new session; no global/program-wide blocklist.

4. **Consent + license persistence.** Record per-participant consent scope (`full` or `decline` on ingest; `timed_out` sessions never reach the API). Record per-participant license flags (`no_llm_training`, `no_public_release`) with mutation history. Every consent or license change emits an audit log row. For mixed-track artifacts, the data-api exposes aggregate license flags as the most-restrictive union across contributors.

5. **PCM chunk storage.** Accept raw-bytes uploads via `POST /internal/sessions/{id}/audio/{pseudo_id}/chunk` with headers `X-Capture-Started-At`, `X-Duration-Ms`, `X-Client-Chunk-Id` (for retry idempotency). Server assigns `seq` monotonically per `(session_id, pseudo_id)`. Storage layout `sessions/<guild>/<session_id>/audio/<pseudo_id>/chunk_<seq>.pcm`. Reserved `pseudo_id = "mixed"` for the mix stream; non-mixed pseudo_ids must belong to the session's participants. Chunk hard max 3 MB. Expose list + streaming download for downstream services.

6. **Session metadata blob.** Per-session JSON document, opaque to the API. `POST` replaces entirely, `PATCH` shallow-merges top-level keys, `GET` fetches. No schema enforcement, no size cap. Versioned via `schema_version` field (informational). Services write their own keys under uniform CRUD; no ownership checks.

7. **Uniform CRUD for segments / beats / scenes.** Three resources, one semantic: a write is a write regardless of origin. Each resource has `id` (UUID), `session_id`, typed fields (text, timecodes, confidence, flags), an immutable `original` JSONB (captured once at first pipeline-origin write, preserved verbatim through all subsequent human edits), plus `author_service` and `author_user_pseudo_id` on every mutation. Bulk insert dedupes on caller-provided `client_id`. Standard `POST` / `GET` / `PATCH` / `DELETE`.

8. **Combined-audio artifact storage.** Data-api stores the session's mixed audio file as an ordinary chunk artifact under `pseudo_id = "mixed"`, accepted through the standard chunk upload endpoint. The bot produces the mix in real time during recording; the data-api is oblivious to its production. Aggregate license flags for the mix are computed from all contributors as the most-restrictive union.

9. **Real-time event bus (WebSocket).** Single endpoint `GET /internal/ws`, same bearer auth. Clients subscribe with `{ events: [...], filter: { guild_id?, session_id? } }`. Events: `session_state_changed`, `chunk_uploaded`, `segment_created|updated|deleted`, `beat_*`, `scene_*`, `mute_range_created|deleted`, `audio_deleted`. Envelope `{ type, at_ts, data }`. Bounded per-subscriber queue (default 64 events); overflow drops oldest with WARN + counter. No persistence, no replay — queue is the restart buffer. Server sends ping every 30s; subscribers have 10s to pong.

10. **Structural pseudonymization at ingest.** The schema is physically incapable of storing Discord user IDs. Every user-identifying column is `pseudo_id TEXT` with CHECK constraint `^[0-9a-f]{24}$` (24 hex chars = 96 bits; collision-resistant at any plausible scale). Derivation `hex(sha256(discord_user_id_utf8))[0:24]` is stable across dev and prod (no per-env salt). A `user_display_names (pseudo_id, display_name, first_seen_at, last_seen_at, seen_count, source)` table stores mutable display-name aliases, cascade-delete on user wipe. CI job grep-blocks any migration that introduces a disallowed column name (`discord_id`, `user_id`, etc.).

11. **Mute ranges and permanent deletion.** Two orthogonal post-hoc controls.
    - **Mute range:** `POST /internal/sessions/{id}/participants/{pid}/mute { start_offset_ms, end_offset_ms, reason }` creates a time-range mute overlay. Reversible via `DELETE`, listable via `GET`. Chunks themselves are never modified; mutes are applied at render/playback/release time. Multiple ranges allowed; overlap is merged at read.
    - **Permanent deletion:** `DELETE /internal/sessions/{id}/participants/{pid}/audio` physically removes chunks + cascading pipeline outputs for that participant. Irreversible. Audit tombstone retained. SLO: 30 days from request (tighten to 7 at Phase 3).

12. **Observability.** `GET /metrics` (Prometheus, loopback-only) exposes request counters + latency histograms, DB pool + query timings, S3 op counters + latencies + bytes, WebSocket subscriber count + events sent + drops + disconnects, domain gauges (sessions-by-status). Structured `tracing` spans on every request with child spans for DB and S3 calls. `ws_send` spans sampled at 1/100 to avoid volume blowup. `GET /health/live` (process alive) and `GET /health/ready` (DB + S3 reachable) are separate; both unauthenticated.

---

## Interfaces

Grouped by concern. All `/internal/` endpoints require `Authorization: Bearer <session_token>` except `/internal/auth` itself. Responses are JSON unless noted; errors follow `{ error: "message" }` with appropriate HTTP status.

### Auth

- `POST /internal/auth` *(unauth'd)* — `{ shared_secret, service_name }` → `{ session_token }`
- `POST /internal/heartbeat` — no body; updates `last_seen_at` on the caller's session row

### Sessions

- `POST /internal/sessions` — create. Body: `{ id, guild_id, started_at, game_system?, campaign_name?, s3_prefix }`. Initial state = `recording`
- `GET /internal/sessions/{id}` — fetch
- `GET /internal/sessions?status=&guild_id=&limit=&offset=` — list with filters
- `PATCH /internal/sessions/{id}` — `{ status?, ended_at?, participant_count? }`; server enforces valid transitions (rejects illegal with 409)
- `POST /internal/sessions/{id}/resume` — `abandoned → recording` within `RESUME_TTL`. Body: `{ resumed_by_service_name, reason? }`
- `POST /internal/sessions/{id}/delete` — cascade delete (chunks, metadata, segments, beats, scenes); tombstone row retained
- `GET /internal/sessions/{id}/summary` — aggregated stats: `{ chunk_count, participant_count, duration_ms, segment_count, beat_count, scene_count, mute_range_count, aggregate_license_flags }`

### Users + participants

- `POST /internal/users` — upsert by pseudo_id
- `GET /internal/users/{pseudo_id}` — fetch user row + latest display name
- `POST /internal/users/{pseudo_id}/display_names` — record seen alias (idempotent on `(pseudo_id, display_name)`)
- `GET /internal/users/{pseudo_id}/display_names` — list aliases ordered by `last_seen_at`
- `POST /internal/sessions/{id}/participants` — add single
- `POST /internal/sessions/{id}/participants/batch` — add many
- `GET /internal/sessions/{id}/participants` — list
- `GET /internal/participants/{id}` — fetch
- `PATCH /internal/participants/{id}/consent` — `{ consent_scope, consented_at }`
- `PATCH /internal/participants/{id}/license` — `{ no_llm_training?, no_public_release? }`

### Audio chunks

- `POST /internal/sessions/{id}/audio/{pseudo_id}/chunk` — raw PCM body, required headers: `X-Capture-Started-At`, `X-Duration-Ms`, `X-Client-Chunk-Id`. Returns `{ seq, s3_key }`. Idempotent on `X-Client-Chunk-Id`. Hard max body 3 MB
- `GET /internal/sessions/{id}/audio/{pseudo_id}/chunks` — list chunk metadata rows
- `GET /internal/sessions/{id}/audio/{pseudo_id}/chunk/{seq}` — stream raw bytes

### Session metadata blob

- `POST /internal/sessions/{id}/metadata` — replace entirely
- `PATCH /internal/sessions/{id}/metadata` — shallow merge of top-level keys
- `GET /internal/sessions/{id}/metadata` — fetch

### Segments / beats / scenes

Three resources with identical surface shape. Showing segments as the template:

- `POST /internal/sessions/{id}/segments` — bulk insert `{ segments: [{ client_id, ...fields }, ...] }`; idempotent on `(session_id, client_id)`
- `GET /internal/sessions/{id}/segments?pseudo_id=&since_ms=` — list with filters
- `GET /internal/segments/{id}` — fetch single
- `PATCH /internal/segments/{id}` — partial update, body may include `author_user_pseudo_id`
- `DELETE /internal/segments/{id}` — remove
- Beats at `/internal/sessions/{id}/beats` + `/internal/beats/{id}` — same shape
- Scenes at `/internal/sessions/{id}/scenes` + `/internal/scenes/{id}` — same shape

### Mute + post-hoc deletion

- `GET /internal/sessions/{id}/participants/{pid}/mute` — list active mute ranges
- `POST /internal/sessions/{id}/participants/{pid}/mute` — `{ start_offset_ms, end_offset_ms, reason }` → `{ range_id }`
- `DELETE /internal/sessions/{id}/participants/{pid}/mute/{range_id}` — reverse
- `DELETE /internal/sessions/{id}/participants/{pid}/audio` — permanent wipe across the session for that participant. Cascades chunks + pipeline outputs; audit tombstone retained

### Audit log

- `GET /internal/audit?session_id=&resource_type=&since=&limit=` — query audit rows

### Real-time event bus

- `GET /internal/ws` — WebSocket upgrade, bearer auth in upgrade headers

Client-to-server frames (JSON):

```json
{ "type": "subscribe",   "events": ["chunk_uploaded","segment_created"], "filter": { "guild_id": 123 } }
{ "type": "unsubscribe", "events": ["segment_created"] }
```

Server-to-client frames (JSON):

```json
{ "type": "subscribed",             "active_filters": [...] }
{ "type": "chunk_uploaded",         "at_ts": "...", "data": { "session_id": "...", "pseudo_id": "...", "seq": 42, "size_bytes": 2097152 } }
{ "type": "session_state_changed",  "at_ts": "...", "data": { "session_id": "...", "old": "recording", "new": "uploaded" } }
{ "type": "segment_created",        "at_ts": "...", "data": { "session_id": "...", "id": "..." } }
/* segment_updated|deleted, beat_created|updated|deleted, scene_created|updated|deleted, mute_range_created|deleted, audio_deleted */
```

Ping/pong every 30s; 10s grace before server drops.

### Observability (unauth'd, loopback-only)

- `GET /metrics` — Prometheus scrape
- `GET /health/live` — `{ ok: bool }` — process alive
- `GET /health/ready` — `{ ok: bool, db: bool, s3: bool }` — dependencies reachable

### Environment variables

| Var | Required | Default | Meaning |
|---|---|---|---|
| `SHARED_SECRET` | yes | — | Cross-service auth secret |
| `DATABASE_URL` | yes | — | Postgres connection URL |
| `S3_ENDPOINT` | yes | — | S3-compatible endpoint URL |
| `S3_ACCESS_KEY` | yes | — | S3 access key |
| `S3_SECRET_KEY` | yes | — | S3 secret key |
| `S3_BUCKET` | yes | — | Target bucket |
| `BIND_ADDR` | no | `0.0.0.0:8001` | HTTP listen address |
| `RESUME_TTL_SECS` | no | `86400` | Abandoned-session resume deadline (24 h) |
| `HEARTBEAT_REAP_SECS` | no | `90` | Service-session inactivity timeout |
| `WS_QUEUE_DEPTH` | no | `64` | Per-subscriber event queue cap |
| `RUST_LOG` | no | `chronicle_data_api=info,tower_http=info` | tracing filter |

---

## Behavior

### Invariants (always hold)

1. **Pseudonymization at ingest.** No endpoint accepts or returns a Discord user ID. Pseudo_id validation (24 hex chars) at middleware before any handler runs.
2. **Session state transitions are server-enforced.** Clients propose a transition; server accepts or rejects per the state machine in Features §2. Invalid transitions return 409.
3. **Audit log is append-only.** Every mutation (POST / PATCH / DELETE across any resource) writes one row. Audit log rows are never deleted except when a session is hard-deleted (tombstone cascade).
4. **Chunk `seq` is monotonic per `(session_id, pseudo_id)`.** Server-assigned at POST time; clients do not control it. Idempotent retry via `X-Client-Chunk-Id` returns the existing row without re-incrementing.
5. **Event bus is fire-and-forget.** Events are never persisted or replayed. Subscribers that miss events recover by reconciling via REST reads.
6. **The data-api is stateless across restarts except for its Postgres + S3 state.** All in-memory state (WS subscribers, service sessions) is rebuilt on restart. Clients re-auth and re-subscribe transparently.
7. **Optimistic concurrency on mutable blobs and editable rows.** Metadata blob, segment / beat / scene PATCH responses include an `ETag` header. Subsequent PATCHes must send `If-Match: <etag>`; mismatch returns 412 Precondition Failed. Protects against last-write-wins on concurrent edits.

### Lifecycle of a typical session (happy path)

```
bot     : POST /sessions                                 (creates row, status=recording)
bot     : POST .../participants/batch                    (enrols everyone)
bot     : PATCH participant consent (full, per user)
bot     : PATCH participant license (defaults)
bot     : POST .../audio/<pseudo_id>/chunk               (raw bytes, many times)
bot     : POST .../audio/mixed/chunk                     (raw bytes, many times)
bot     : POST .../metadata                              (initial blob)
bot     : PATCH session status=uploaded
worker  : subscribes to WS, sees session_state_changed
worker  : PATCH session status=transcribing
worker  : POST .../segments, .../beats, .../scenes       (bulk)
worker  : PATCH session status=transcribed
worker  : PATCH .../metadata                             (pipeline stats, If-Match with current ETag)
```

### Behavior under partial / concurrent writes

- **Two services PATCH the same metadata concurrently:** both send `If-Match`. First wins, second gets 412; second re-fetches, merges its changes locally, retries PATCH with new ETag. Clients must handle 412.
- **Two services PATCH the same segment / beat / scene concurrently:** same `If-Match` flow, same 412 semantics.
- **Idempotent chunk retries:** same `X-Client-Chunk-Id` returns the existing row's `{ seq, s3_key }`. No WS event fires on the retry.
- **Idempotent bulk-insert retries:** segments with previously-seen `client_id` are silently dropped from the insert; newly-provided `client_id`s are inserted. Response reports both inserted and deduplicated counts.

### Cascades

- **Session `POST /delete`:** chunks deleted from S3, chunk rows deleted, participants + consent + license + segments + beats + scenes + mute_ranges + metadata deleted, session row kept as tombstone with `status=deleted, deleted_at`, audit row recording the initiator.
- **Participant `DELETE /audio`:** cascade scoped to that participant only. Chunks + segments (filtered by pseudo_id) + mute_ranges deleted. Participant row + consent row preserved with a `data_wiped_at` flag so future sessions can see the prior wipe request.
- **Session `resume`:** no cascade. State transitions `abandoned → recording`. Audit row inserted. WS event fires.

### Error handling

- **Database errors:** 500, log at `ERROR`. Client retries.
- **S3 errors on chunk upload:** 502 with `{ error: "s3 put failed", retryable: true }`. Client retries using the same `X-Client-Chunk-Id`.
- **S3 errors on chunk read:** 502; client can retry.
- **Auth failures:** 401, force client to re-auth. Auth middleware never logs token values.
- **Pseudo_id validation failures:** 400 with `{ error: "invalid pseudo_id format: expected 24 hex chars" }`.
- **ETag mismatch:** 412 with `{ error: "if-match precondition failed", current_etag: "..." }`.
- **Panic in a handler:** tower middleware catches, returns 500, logs full trace. Process stays up.

### Ordering guarantees

- **WS events for a single session:** ordered within a subscriber. A subscriber receiving `chunk_uploaded` events for session X sees them in `seq` order.
- **Cross-session ordering:** no guarantee. Events from different sessions can interleave arbitrarily. Subscribers that need cross-session ordering reconcile via REST.
- **Chunk upload order:** server assigns seq in the order POSTs are accepted. A slow POST followed by a fast POST on the same pseudo_id will produce seqs in POST-completion order, not client-issue order. The bot serializes per-participant uploads so this does not surface in practice.

### WebSocket subscriber behavior

- On connect + subscribe, subscriber receives events from that moment forward. No backfill.
- Server keeps a per-subscriber bounded queue (default `WS_QUEUE_DEPTH=64`). If the queue fills because the subscriber is slow reading, oldest event is dropped. `chronicle_ws_events_dropped_total{subscriber}` increments. Log at WARN.
- If drops sustain (>10/min from a single subscriber), server disconnects. Subscriber is expected to reconnect + reconcile via REST.
- Ping/pong is server-initiated every 30s. Missed pong → disconnect with reason `healthcheck_timeout`.

### Retention

- Chunks, metadata, and pipeline outputs: retained until explicit deletion (`POST /sessions/{id}/delete` or `DELETE /participants/{pid}/audio`). No TTL-based auto-cleanup at the data-api layer.
- Audit log rows: retained for the lifetime of the session (until tombstone cascade). *(Independent audit-log retention window for post-deletion forensics is a deferred decision.)*
- WS events: not persisted. Retention is literally the per-subscriber queue depth — seconds of activity at bulk-insert rates.

### Scope fence

The data-api does **not**:

- Transcribe, mix audio, render combined files, run VAD, detect beats/scenes, or any other inference work.
- Manage user-facing authentication. All auth is shared-secret service-level.
- Push notifications to end users.
- Enforce permission / authorization beyond "is this a valid service session token." No read vs write scopes.
- Schedule or orchestrate work. Workers decide when to pick things up; the data-api serves state and events.
- Deduplicate audio content cross-session (e.g., noticing the same 30s chunk appeared in two sessions — that's a pipeline concern).
- Expose any public-facing surface. Ever. If the portal wants portal-facing reads, it does so through its BFF layer.

Additions require explicit Features entry with Interfaces + Behavior implications called out.
