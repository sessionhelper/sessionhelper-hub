# chronicle-worker

Glue service between `chronicle-data-api` and `chronicle-pipeline`. Subscribes to data-api events, drives the pipeline on active sessions, writes pipeline outputs back. Stateless across restarts; multiple worker replicas can run concurrently, coordinating via atomic session claims in the data-api.

Status: **Features locked. Interfaces and Behavior pending.** Implementation at `/home/alex/sessionhelper/chronicle-worker/`.

---

## Features

1. **Event-driven pipeline invocation.** Subscribes to the data-api WebSocket bus. On `chunk_uploaded` for active sessions, feeds chunks through a running `Pipeline` (streaming mode). On `session_state_changed` to `uploaded`, finalizes any active pipelines for that session and advances the state through `transcribing → transcribed`.

2. **Session claim model.** When a session transitions to `uploaded`, the worker atomically claims it by PATCHing to `transcribing`. The data-api rejects concurrent claims via state-machine enforcement — first write wins; losers see 409 and skip. This enables multiple worker replicas without any external coordination.

3. **Streaming pipeline per active session.** One `Pipeline` instance per active session, running in its own tokio task. Chunks arrive from WS and are forwarded to that session's pipeline. When `finalize()` fires, outputs bulk-upload to data-api.

4. **Whisper client.** Owns the `WhisperClient` impl — an HTTP client targeting `WHISPER_URL` from env. Pipeline-internal retries (3× exp backoff from 500 ms). On exhaustion, the specific voice region is marked `DroppedRecord`; the session continues. Sustained outages surface via `chronicle_worker_sessions_failed_total` + the session-level retry schedule (Feature 6). No circuit breaker — operators monitor the failure counter and invoke admin rerun after confirming Whisper recovery.

5. **Idempotent re-runs.** Sessions can be re-processed on demand (admin command). The worker clears prior pipeline outputs (segments, beats, scenes — not chunks, not metadata), resets state to `transcribing`, and re-processes in one-shot mode.

6. **Auto-retry on transient failures.** Pipeline errors that don't trip the circuit breaker advance the session to `transcribing_failed` and schedule a retry. 3 attempts total, exponential backoff (30 s, 2 m, 10 m). After exhaustion, stays `transcribing_failed` until manually retried. Pipeline `DroppedRecord` entries never count as failures — those are logged but normal.

7. **Orphaned-session reconciliation on startup.** On boot, the worker lists `uploaded` and `transcribing` sessions from the data-api. `uploaded` sessions get claimed normally. `transcribing` sessions are assumed orphaned (a prior worker died mid-run); the worker re-runs them in one-shot mode. Re-runs are idempotent (see Feature 5), so re-processing already-completed work is safe.

8. **Admin-triggered re-runs.** An operator-facing endpoint (invoked by admin tooling, not automatically) forces re-processing of any session regardless of its current state. Used after pipeline version bumps, config changes, or ad-hoc investigation. Worker itself does not auto-rerun on pipeline version change — too much compute for background churn.

9. **Multi-session parallelism in one process.** Runs sessions concurrently in separate tokio tasks; no shared state between them beyond the Whisper client and data-api client. Horizontal scaling: run more worker replicas; the data-api claim model arbitrates.

10. **Observability.** Per-session tracing span (`session{session_id}`), metrics for sessions claimed / transcribed / failed / retried, pipeline-level metrics aggregated from the library, Whisper call latency histogram, circuit-breaker state gauge.

---

## Interfaces

### Inbound — data-api WebSocket subscription

Subscribes on startup after exchanging `SHARED_SECRET` for a session token. Events consumed: `session_state_changed`, `chunk_uploaded`. No `guild_id` filter (worker handles all guilds).

### Inbound — dev/test admin HTTP (`WORKER_ADMIN_ENABLED=true`, loopback-only)

- `POST /admin/rerun/{session_id}` → forces re-processing regardless of current state. Returns `{ queued: bool }`
- `GET /admin/status` → `{ active_sessions: [...], last_heartbeat_at, version }`

Disabled entirely in production (no port opened). Used in dev by humans (via SSH tunnel) and test orchestration (via the container network).

### Outbound — data-api (HTTP, shared-secret auth)

- `PATCH /internal/sessions/{id}` — state transitions (`uploaded → transcribing → transcribed` or `→ transcribing_failed`)
- `GET /internal/sessions?status=uploaded` and `?status=transcribing` — startup reconciliation
- `GET /internal/sessions/{id}/audio/{pseudo_id}/chunk/{seq}` — pull chunk bytes for one-shot rerun
- `POST /internal/sessions/{id}/segments|beats|scenes` — bulk insert outputs
- `DELETE /internal/segments/{id}|beats/{id}|scenes/{id}` — clear prior outputs on rerun
- `PATCH /internal/sessions/{id}/metadata` — append pipeline stats
- `POST /internal/heartbeat` — service-session keepalive

### Outbound — Whisper HTTP

POSTs to `WHISPER_URL` for transcription. Retry: 3× exponential backoff from 500 ms. On exhaustion, the pipeline marks the region `DroppedRecord` and continues.

### Outbound — chronicle-pipeline (Rust crate)

Constructs `Pipeline` per active session, injects `WhisperClient`, drives `ingest_chunk` / `emit` / `finalize`.

### Environment variables

| Var | Required | Default | Meaning |
|---|---|---|---|
| `DATA_API_URL` | yes | — | e.g. `http://data-api:8001` |
| `SHARED_SECRET` | yes | — | Cross-service auth |
| `WHISPER_URL` | yes | — | Whisper server base URL |
| `WHISPER_MODEL` | no | `Systran/faster-whisper-large-v3` | Model name for requests |
| `VAD_MODEL_PATH` | yes | — | Path to bundled Silero ONNX |
| `POLL_INTERVAL_SECS` | no | `10` | REST fallback poll when WS is down |
| `WORKER_ADMIN_ENABLED` | no | `false` | Enables the admin HTTP surface |
| `ADMIN_BIND_ADDR` | no | `127.0.0.1:8020` | Admin HTTP bind |
| `RETRY_BACKOFF_MS` | no | `30000,120000,600000` | CSV: 3 retry delays (30 s, 2 m, 10 m) |
| `RUST_LOG` | no | `chronicle_worker=info,chronicle_pipeline=info` | tracing filter |

### Observability

Tracing: `session{session_id}` per active session; nested `operator{name}` spans from the pipeline library.

Metrics:

- `chronicle_worker_sessions_active` — gauge
- `chronicle_worker_sessions_claimed_total` — counter
- `chronicle_worker_sessions_transcribed_total` — counter
- `chronicle_worker_sessions_failed_total{reason}` — counter (`pipeline_error`, `timeout`)
- `chronicle_worker_retries_total` — counter
- `chronicle_worker_whisper_latency_ms` — histogram
- Pipeline-library metrics re-emitted through the worker's aggregator

---

## Behavior

### Invariants (always hold)

1. **Every `uploaded` session eventually reaches `transcribed` or `transcribing_failed`.** The worker never leaves sessions stuck. Orphaned `transcribing` rows are re-run on startup; `transcribing_failed` gets auto-retried 3× then holds until manual retry.
2. **Atomic claim via data-api.** Two workers racing to claim the same session: first PATCH wins, second sees 409 and backs off. No other coordination required.
3. **Stateless across restarts.** All in-memory state (active pipelines, WS subscription) is rebuilt on boot. Reconciliation handles the rest.
4. **Idempotent reruns.** Clearing prior outputs + one-shot re-run produces equivalent segments / beats / scenes for identical audio. Safe to invoke repeatedly.
5. **Data-api is the source of truth.** The worker never caches session state longer than the active-session map demands.

### Startup flow

```
worker : auth against data-api with SHARED_SECRET
worker : subscribe to WS { session_state_changed, chunk_uploaded }
worker : GET /sessions?status=uploaded → for each: PATCH → transcribing; on claim win, start streaming pipeline (backfill already-uploaded chunks via GET, then live stream)
worker : GET /sessions?status=transcribing → treat as orphans; attempt idempotent claim, run one-shot mode
worker : begin normal event loop
```

Orphan claim relies on `transcribing → transcribing` being a valid no-op transition in the data-api state machine. This keeps claim logic uniform and avoids a separate "acquire" endpoint.

### Event loop

```
loop {
    select! {
        event        = ws.next()         => dispatch_ws_event(event)
        _            = poll_timer.tick() => reconcile_via_rest_poll()
        retry_ready  = retry_queue.next()=> attempt_retry(retry_ready)
    }
}
```

- **`chunk_uploaded`:** look up active `Pipeline` for that session; if present, fetch chunk via data-api GET, feed `ingest_chunk`. If no active pipeline, log + ignore (late event for a finalized session).
- **`session_state_changed → uploaded`:** attempt claim. On win, start a `Pipeline` in streaming mode. Begin draining any already-queued `chunk_uploaded` events for that session.
- **WS disconnect:** immediate reconnect with exponential backoff. `POLL_INTERVAL_SECS` REST poll as a safety net catches missed `uploaded` transitions while disconnected.

### Near-live transcription

Worker processes chunks **as they arrive** during an active session (streaming mode). The bot is still recording; the worker is transcribing what's already uploaded. Outputs flow to the data-api live; the portal can display transcripts with a few-second lag behind the live audio.

When the session transitions `recording → uploaded` (bot finished), the worker's already-running pipeline runs `finalize()` to flush any remaining buffered state, writes the last outputs, and advances the session to `transcribed`.

### Pipeline lifecycle per session

**Streaming (normal):**

```
start    : Pipeline::builder().config(cfg).deps(deps).build()
backfill : GET chunks already uploaded (seq 0..max), ingest_chunk for each
live     : on WS chunk_uploaded, fetch + ingest_chunk
emit     : pipeline.emit() between chunks → bulk POST outputs
finalize : on session → uploaded, pipeline.finalize() → bulk POST remaining → PATCH status=transcribed
```

**One-shot (reruns, orphan recovery):**

```
pull    : GET all chunks for the session in seq order
run     : Pipeline::new(...).run_one_shot(all_chunks)
emit    : bulk POST outputs
finish  : PATCH status=transcribed
```

### Retry policy

Session transitions to `transcribing_failed` schedule a retry in a background `JoinSet` task:

- Attempt 1: 30 s after failure
- Attempt 2: 2 min after failure
- Attempt 3: 10 min after failure
- After attempt 3: stays `transcribing_failed` indefinitely until `POST /admin/rerun/{id}` or admin PATCHes state back to `uploaded`.

Each retry does a fresh one-shot run from chunks. Transient network blips *within* a run (single chunk POST failing, single Whisper call failing) are handled by inner retry in reqwest / pipeline respectively — they don't escalate to a session-level retry.

### Error handling

- **Data-api unreachable:** worker logs, pauses new work, reconnect loop runs. Active pipelines keep their in-memory state; when data-api returns, outputs flush. If flush fails after reasonable retries, session → `transcribing_failed`.
- **S3 unreachable for chunk reads:** current pipeline marked `transcribing_failed` (retryable).
- **Pipeline `PipelineError`:** captured at the worker boundary. Session → `transcribing_failed`. Error details logged; retryable.
- **Operator panic propagated as `PipelineError::OperatorFailed`:** treated as retryable unless the specific `operator + message` matches a known-non-retryable list (bad model path, config invalid), in which case session stays `transcribing_failed` without auto-retry.

### Scope fence

The worker does **not**:

- Modify chunks, metadata, session rows, or any data not owned by it (pipeline outputs + session state transitions only).
- Host Whisper or run inference locally.
- Perform portal or human-facing duties.
- Coordinate with other workers outside of data-api claim. No gossip, no leader election.
- Touch S3 or Postgres directly — always through data-api.
- Auto-rerun sessions on pipeline version changes. Admin decides what reruns.

Additions require explicit Features entry with Interfaces + Behavior implications.
