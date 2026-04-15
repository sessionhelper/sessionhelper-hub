# chronicle-pipeline

A Rust library (not a service). Pure compute for turning per-speaker PCM into structured session understanding: VAD regions, transcribed segments, beats, scenes, and future analyses. Used by `chronicle-worker` — the worker is the I/O glue, the pipeline is the math.

**Timescale principle.** The pipeline runs at any timescale. Operators compose into a chain that runs from milliseconds (VAD on a single voice frame) through seconds (per-segment transcription) through minutes (scenes, beats) through — eventually — cross-session and dataset-level aggregates. The architecture is the same everywhere: each operator consumes typed inputs from upstream operators + raw session state, produces typed outputs, supports streaming + one-shot modes, has a `finalize()` on end-of-input. Features added later (cross-session character tracking, campaign arc detection, sentiment over time) are new operators, not a new pipeline.

Status: **Features locked. Interfaces and Behavior pending.** Implementation at `/home/alex/sessionhelper/chronicle-pipeline/`.

---

## Features

1. **Operator chain architecture.** The only "feature" that matters in shape: operators compose. Every other feature below is an operator or group of operators. Chain composition is declarative (ordered list of operator configs); operators can be added, removed, or reordered without framework changes. Each operator has `ingest(input)`, `emit() -> Vec<output>`, `finalize() -> Vec<output>`. All operators support streaming + one-shot modes through the same trait surface. Operators are pure; I/O goes through caller-supplied dependencies.

2. **VAD operator.** Silero VAD over per-speaker PCM streams. Produces timed voice regions `(pseudo_id, start_ms, end_ms)`. ONNX model bundled at a known path.

3. **Transcription operator.** Consumes VAD regions + original PCM, calls a caller-supplied Whisper HTTP endpoint, produces `(region_ref, text, confidence, language)`. Retry policy: 3 attempts with exponential backoff from 500 ms. Whisper is configured as an endpoint URL at call time; the pipeline does not host inference.

4. **Filtering operator (hallucinations + noise).** Consumes transcription output. Drops Whisper hallucinations (known-pattern noise like "Thank you.", impossibly-fast speech, very-low-confidence text). Heuristics are inline constants for now; externalizable later. Dropped items log the reason + emit a metric.

5. **Segment operator.** Joins filtered transcription output with VAD region metadata; produces canonical `segment` records `(id, pseudo_id, start_ms, end_ms, text, confidence)`. Segments are the canonical unit downstream — beats and scenes anchor to segments.

6. **Meta-talk classifier operator.** Per-segment classification: `in_character` / `out_of_character` / `mixed` / `unclear`. Rule-based + small-model heuristics for MVP. Output is a flag appended to the segment's `flags` JSONB, not a separate resource.

7. **Beat detection operator.** Consumes segment stream, emits `(t_ms, kind, label, confidence)`. Kinds are a closed, versioned enum (`combat_start`, `combat_end`, `discovery`, `dialogue_climax`, `scene_break`, etc.). The enum evolves; the shape is stable.

8. **Scene chunker operator.** Consumes segments + beats, groups into coherent scenes `(start_ms, end_ms, label, confidence)`. Larger-grained than beats (minutes, not seconds).

9. **Pure-library I/O.** Inputs via typed structs (chunks, config, Whisper client). Outputs via typed structs (per-operator output enums). No HTTP, file, database, or S3 access except through caller-supplied dependencies. Unit-testable without infra.

10. **Streaming + one-shot duality.** Two calling shapes:
    - **Streaming:** incremental `ingest()` calls as chunks arrive; `emit()` returns partial outputs as operators finalize regions / segments / beats / scenes. Used by `chronicle-worker` during live session processing.
    - **One-shot:** full session audio in, full outputs out in one call. Used for batch re-runs over older sessions when operators change.
    Identical internal code, driven by the same trait surface.

11. **Observability.** Per-operator tracing spans (`operator{name}`) wrapping `ingest` / `emit` / `finalize`. Metrics: per-operator throughput, input / output counts, latency, drop reasons (filter operator). Emission via `tracing` and `metrics` crates; the worker aggregates and scrapes.

---

## Interfaces

This is a Rust library; its contract is its public types and traits. Consumers use the `Pipeline` builder, inject dependencies, and drive it in streaming or one-shot mode.

### Core operator trait

```rust
pub trait Operator: Send + 'static {
    type Input;
    type Output;

    async fn ingest(&mut self, input: Self::Input) -> Result<(), PipelineError>;
    fn emit(&mut self) -> Vec<Self::Output>;
    async fn finalize(&mut self) -> Result<Vec<Self::Output>, PipelineError>;
    fn name(&self) -> &'static str;
}
```

Async trait: transcription is naturally async (HTTP); sync operators implement async fns that just return immediately.

### Pipeline composition

```rust
pub struct Pipeline { /* ordered operators with typed adapters */ }

impl Pipeline {
    pub fn builder() -> PipelineBuilder;

    // Streaming
    pub async fn ingest_chunk(&mut self, chunk: AudioChunk) -> Result<(), PipelineError>;
    pub fn emit(&mut self) -> PipelineOutput;
    pub async fn finalize(&mut self) -> Result<PipelineOutput, PipelineError>;

    // One-shot
    pub async fn run_one_shot(self, audio: SessionAudio) -> Result<PipelineOutput, PipelineError>;
}

pub struct AudioChunk {
    pub session_id: SessionId,
    pub pseudo_id: PseudoId,
    pub seq: u32,
    pub capture_started_at: Timestamp,
    pub duration_ms: u32,
    pub pcm: Vec<i16>,                          // 48 kHz stereo s16le
}

pub struct PipelineOutput {
    pub segments: Vec<Segment>,
    pub beats: Vec<Beat>,
    pub scenes: Vec<Scene>,
    pub dropped: Vec<DroppedRecord>,            // with reason
}
```

### Caller-supplied dependencies

```rust
pub trait WhisperClient: Send + Sync {
    async fn transcribe(
        &self,
        audio: &[i16],
        sample_rate: u32,
    ) -> Result<Transcription, WhisperError>;
}

pub struct PipelineDeps {
    pub whisper: Arc<dyn WhisperClient>,
    pub vad_model_path: PathBuf,
}
```

The worker builds a `WhisperClient` against its configured Whisper URL and injects it. The pipeline never knows the URL.

### Output types

All output types derive `Serialize + Deserialize` with `#[serde(rename_all = "snake_case")]` and `#[serde(default)]` on non-essential fields, so adding fields is forward-compatible. Downstream (data-api, portal) stores them as JSON rows.

```rust
pub struct Segment {
    pub id: Uuid,
    pub session_id: SessionId,
    pub pseudo_id: PseudoId,
    pub start_ms: u64,
    pub end_ms: u64,
    pub text: String,
    pub confidence: f32,
    pub language: Option<String>,
    pub flags: SegmentFlags,                    // meta-talk classification etc.
}

pub struct Beat {
    pub id: Uuid,
    pub session_id: SessionId,
    pub t_ms: u64,
    pub kind: BeatKind,                         // closed, versioned enum
    pub label: String,
    pub confidence: f32,
}

pub struct Scene {
    pub id: Uuid,
    pub session_id: SessionId,
    pub start_ms: u64,
    pub end_ms: u64,
    pub label: String,
    pub confidence: f32,
}

pub struct DroppedRecord {
    pub source_operator: &'static str,
    pub reason: DropReason,
    pub details: serde_json::Value,
}

pub enum BeatKind {
    CombatStart,
    CombatEnd,
    Discovery,
    DialogueClimax,
    SceneBreak,
    // Evolves over time. Deserialization uses `#[serde(other)]` on an
    // `Unknown(String)` variant so old consumers don't explode when new
    // kinds appear.
}
```

### Configuration

```rust
pub struct PipelineConfig {
    pub operators: Vec<OperatorKind>,           // declarative order
    pub vad: VadConfig,
    pub transcription: TranscriptionConfig,
    pub filter: FilterConfig,
    pub meta_talk: MetaTalkConfig,
    pub beats: BeatsConfig,
    pub scenes: ScenesConfig,
}

pub enum OperatorKind { Vad, Transcription, Filter, Segment, MetaTalk, Beats, Scenes }
```

### Error type

```rust
pub enum PipelineError {
    Vad(VadError),
    Whisper(WhisperError),
    InvalidInput(String),
    ConfigInvalid(String),
    OperatorFailed { operator: &'static str, source: Box<dyn std::error::Error + Send + Sync> },
}
```

Single enum. Callers handle via `match` or just propagate with `?`.

### Observability

Tracing spans: `operator{name}` wrapping `ingest` / `emit` / `finalize`. `whisper_call{region_ms, bytes}` around HTTP.

Metrics (via `metrics` crate, scraped by the worker):

- `chronicle_pipeline_operator_ingest_latency_us{operator}` — histogram
- `chronicle_pipeline_operator_emit_count{operator}` — counter
- `chronicle_pipeline_operator_dropped_total{operator, reason}` — counter
- `chronicle_pipeline_whisper_retries_total` — counter
- `chronicle_pipeline_whisper_latency_ms` — histogram

---

## Behavior

### Invariants (always hold)

1. **Purity.** No operator performs I/O except through the injected `WhisperClient`. The pipeline never opens a file (beyond the VAD model path), network socket, database connection, or S3 client.
2. **Operator isolation.** Each operator holds only its own state. No shared mutable state across operators. Data flows downstream via typed adapters: previous operator's `Vec<Output>` → next operator's `Input`.
3. **`finalize()` is always called.** Whether one-shot or streaming, the `Pipeline` guarantees `finalize()` fires once for every operator at end-of-input before returning the final `PipelineOutput`. Operators accumulating incomplete regions (VAD with an open voice region, beat detector with pending segments) flush them in finalize.
4. **Streaming and one-shot produce identical outputs** given identical input. Enforced via CI property test: feeding the same audio in 100 ms increments vs. one shot yields byte-identical segment / beat / scene sets modulo v7 UUID assignment. This is a canary — regressions break CI.
5. **Deterministic ordering.** `PipelineOutput.segments` / `beats` / `scenes` are sorted by `start_ms` (then `t_ms` for beats). Operators emit in creation order; the pipeline sorts at emit time.
6. **UUIDs assigned in pipeline.** `id` fields are v7 (time-ordered), assigned by the originating operator. Same audio re-run gets different `id`s but structurally equivalent outputs.

### Streaming flow

```
worker : chunk arrives from data-api
worker : pipeline.ingest_chunk(chunk).await
  pipeline : routes PCM to VAD operator for this pseudo_id
    VAD : accumulates PCM, emits when a voice region closes
  pipeline : feeds closed VAD regions to Transcription operator
    Transcription : calls WhisperClient, gets text, feeds to Filter
      Filter : heuristic keeps/drops; passes keepers to Segment operator
        Segment : assembles final Segment record
  pipeline : segments fan into MetaTalk (flags them), then Beats, then Scenes (as their time thresholds permit)
worker : pipeline.emit() returns currently-drainable output
worker : persists to data-api
```

Each operator maintains enough state to handle late-arriving input without backtracking (VAD's moving-window buffer; Beat detector's lookback window on segments). If an operator needs to look further back than its window, that's a config change, not a framework change.

### One-shot flow

Semantically identical to streaming with a single `finalize()` at the end. Same operator code paths.

### Error handling — two tiers

**Per-input errors (recoverable).** An operator that fails to process a specific input (e.g., Whisper exhausted retries on one voice region, VAD rejects a malformed chunk) emits a `DroppedRecord { source_operator, reason, details }` and continues. The session keeps moving; that specific region simply has no downstream output. Transient failures are the norm, not exceptional.

**Pipeline-level errors (non-recoverable).** Only genuine invariant violations produce `PipelineError`:
- Config was invalid at build time (returned from `PipelineBuilder::build()`, not from `ingest`).
- Operator panicked (caught at operator boundary; converted to `PipelineError::OperatorFailed`).
- Input violates the pipeline's type contract (e.g., chunk with wrong sample rate).

When `PipelineError` surfaces during `ingest_chunk`, the pipeline's state is tainted; the caller must tear down and restart. In practice this happens rarely, and the worker treats it as a session-level retry signal.

### Backpressure

Single-threaded within one session — operators run sequentially per chunk. The worker serializing `ingest_chunk` calls is natural backpressure. Multiple sessions are parallelized at the worker level (separate tokio tasks, separate `Pipeline` instances). The pipeline has no internal parallelism beyond the async-ness of `WhisperClient::transcribe`.

If `ingest_chunk` is slow (Whisper taking seconds), the caller's `await` naturally backpressures upstream chunk supply. No explicit queue inside the pipeline.

### Evolution

- **New operator.** Implement `Operator`; add variant to `OperatorKind`; add case to the pipeline builder. No changes to existing operators. Config update to include it in the `operators` list.
- **Removing an operator.** Remove from default `operators` config. Leave the type in place for callers that still want it until fully deprecated.
- **New `BeatKind` variant.** Add it. Old consumers decode unknown variants via serde's `Unknown(String)` fallthrough; they don't crash, they just don't know what to do with it.
- **Output type field addition.** `#[serde(default)]` on the new field. Old JSON parses with the field at its default.

### Scope fence

The pipeline does **not**:

- Host Whisper, run inference, or own any ML model besides the bundled Silero VAD ONNX file.
- Read or write Postgres, S3, HTTP endpoints (other than via the injected `WhisperClient`), or local files (beyond the VAD model path).
- Manage sessions, consent, license, or any Chronicle-domain authorisation. The pipeline operates on `session_id` + `pseudo_id` strings and has no authority to judge whether it should.
- Mix or render audio. (That's `chronicle-bot`'s job for the live mix.)
- Understand data-api schemas. Output types are its own; the worker translates.

Additions require explicit Features entry with Interfaces + Behavior implications.
