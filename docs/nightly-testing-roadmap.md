# Nightly testing roadmap

Tests we want running unattended overnight against `chronicle-dev`.
Each entry: what it proves, where to put it, the failure signal that
should page (or at minimum tag the next morning's report).

Status legend: `[ ]` = not started, `[~]` = scaffolded, `[x]` = running.

---

## [ ] Long-session soak

**What it proves.** The bot survives a multi-hour session without leaking
file handles, growing accum unboundedly, exhausting disk cache, or
stalling under sustained packet flow. Spec target is 4 hours of clean
DAVE capture; longest tested today is ~30 seconds.

**Where it lives.** New script under `chronicle-bot/test-soak/`, driven by:

- `chronicle-feeder` fleet on the dev VPS, looping a long fixture WAV
  (concat of all four stooge clips × 1000 = ~3 hr of audio).
- A single `/record` invoke at start, single `/stop` at the end.
- Sampled health probes every 60s during the run.

**Failure signals.**
- Bot RSS growth >100 MB/hr.
- File-descriptor count growth (`/proc/<pid>/fd` lsof) >50/hr.
- Any `voice_tick_no_decoded` rollup with `silent > 0`.
- Any `dave_heal_fired_total` increment.
- `chronicle_audio_packets_received` rate drops to zero for >10s during
  active feeder play.
- Final session row stuck in any non-`transcribed` state.

**Cadence.** Once nightly. Run starts ~02:00 UTC, must complete by 06:00.

**Effort.** ~3 hours to scaffold; uses existing harness HTTP, just adds
the long fixture + the `top`/`lsof` probes + a teardown that asserts
clean shutdown.

---

## [ ] DAVE heal regression test

**What it proves.** The OP5-heal-on-decrypt-miss path fires exactly
once on a streak crossing the threshold, the 30s debounce blocks
subsequent fires, and the heal cycle (leave → join) actually rejoins
voice. Without this test the heal is a black-box safety net we don't
trust.

**Where it lives.** `chronicle-bot/voice-capture/tests/dave_heal.rs`
(integration) — uses a fake `songbird::Call` (we already have one for
the receiver unit tests) and a stubbed Songbird manager that records
`leave`/`join` invocations.

**Test cases.**

1. `dave_heal_fires_once_at_threshold` — feed
   `DAVE_HEAL_THRESHOLD_TICKS` consecutive `decoded_voice = None`
   packets for one SSRC; assert exactly one `DaveHealRequest` is sent
   on the channel.
2. `successful_decode_resets_streak` — feed N-1 silent then one
   decoded packet, then N-1 silent again; assert no heal request fires.
3. `debounce_holds_for_30s` — fire two threshold crossings 5s apart;
   assert second is suppressed.
4. `actor_consumer_invokes_leave_then_join` — given a heal request
   delivered to the spawned consumer, assert `manager.leave` is called,
   then `manager.join` after the 2s sleep.

**Failure signals.** Test failure surfaces in CI; nightly soak (above)
should also report `dave_heal_fired_total` so we have telemetry that
matches the test's behavior in the field.

**Cadence.** Per-PR (`cargo test`) plus once nightly as part of the
soak environment.

**Effort.** ~30 lines of test code per case; ~2 hours total including
the songbird `Call` mock if we don't already have one.

---

## [ ] Timestamp round-trip

**What it proves.** The wall-clock instant at which audio was captured
makes it cleanly through every stage of the pipeline: bot's
`X-Capture-Started-At` header → data-api `chunks.capture_started_at`
column → worker's `SessionTrack.capture_started_at` (just landed
today) → pipeline VAD region offsets → final `Segment.start_ms`. Drift
here means dataset timestamps are wrong, which silently degrades any
downstream training.

**Where it lives.** `chronicle-bot/test-soak/tests/timeline.spec.ts`
(or wherever the long-session harness lands) — runs as a verification
phase after a controlled 60-second injected session.

**Test recipe.**

1. Inject a session via `inject-session.py` with a known wall-clock
   `started_at` (e.g. `2026-04-15T00:00:00Z`).
2. Each chunk's `X-Capture-Started-At` is `started_at + seq * chunk_dur`.
3. After worker finishes, query
   `GET /internal/sessions/<id>/segments`.
4. For each segment, assert
   `abs(segment.start_ms - expected_start_ms) < 100` where
   `expected_start_ms` is computed from the chunk's
   `capture_started_at` plus the VAD region's intra-chunk offset.

**Failure signals.**
- Segment timestamps drift more than 100ms from the originals.
- Segments appear before any chunk's `capture_started_at`.
- Track ordering reversed (segment from track A appears before track A
  was first captured).

**Cadence.** Per-PR via the inject-session smoke (lightweight: 60s
fixture). Long-form variant runs once nightly inside the soak.

**Effort.** ~1 hour. Existing `inject-session.py` already controls
the input timestamps; need a small Python verifier that does the
diff math against the resulting segments.

---

## Owner / next action

These three are the first concrete commitments under "the bot's
behavior and stability is critical." Pick whichever has the lowest
get-to-green latency next; the order above is also a reasonable
priority order (soak first because it's the unknown-unknown catcher).

Add new entries here as gaps surface — see
`docs/dave-bot-ecosystem.md` for the broader Phase 0 robustness plan
and `reports/overnight-2026-04-14.md` for the bug cascade these tests
exist to prevent re-occurring.
