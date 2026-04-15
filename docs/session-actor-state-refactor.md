# Session actor happy-path state refactor — plan

Status: **stages 1 + 2 landed on main 2026-04-15** (commits
`b9c69b2` + `7be2d92`). Stage 3 (FinalizingState) is unnecessary — the
finalize path exits the actor; there's no need for a persistent typed
state there. Kept for reference below.

## Why

`chronicle-bot/voice-capture/src/session/actor.rs` currently has:

- A clean `Phase` enum in `session/phases.rs`
  (`AwaitingStabilization → Recording → Finalizing/Cancelled/Restarting`).
- A flat `ActorEnv` struct (~25 fields) that holds *everything* the
  actor needs regardless of phase: `session_uuid: Option<Uuid>`,
  `audio_handle: Option<AudioHandle>`, `mixer: Option<MixerChannel>`,
  `op5_rx: Option<…>`, `empty_channel_timer: Option<JoinHandle>`, etc.

Invariants that the code *knows* but the types don't:

| Invariant | Enforced by |
|---|---|
| `session_uuid = Some(…)` iff phase is Recording or Finalizing | Commit discipline + reviewer memory |
| `mixer = Some(…)` iff phase is Recording | Same |
| `audio_handle = Some(…)` for the entire life of the actor | Same (`None` only during the 1-tick assignment gap) |
| `empty_channel_timer` only relevant in Recording | Same |

Every `.unwrap()` / `if let Some(...) = …` in the actor leaks this:
readers have to recompute "is this guaranteed Some here?" by tracing
phase transitions in their head. That's a subtle class of bug — the
F7 auto-stop timer bug we hit during the refactor week was exactly
this shape ("we thought the timer was always set in Recording; a
mid-gate race set it to None and we panicked on stop").

Goal: **invariants become type-level facts**. Code paths that run in
Recording get a `RecordingState` struct with those fields non-optional.
Code paths that run pre-gate can't accidentally touch post-gate state
because they have a `StabilizingState` that doesn't have those fields.

## Target shape

```rust
enum ActorPhase {
    Stabilizing(StabilizingState),
    Recording(RecordingState),
    Finalizing(FinalizingState),
    // Cancelled / Restarting are actor-exit states; no state struct.
}

struct StabilizingState {
    entered_at: DateTime<Utc>,
    pending_flush: JoinSet<Result<(), FlushError>>,
    op5_rx: mpsc::UnboundedReceiver<Op5Event>,
    // … fields legitimately not-yet-set at this phase
}

struct RecordingState {
    gate_opened_at: DateTime<Utc>,
    session_uuid: Uuid,                 // NOT Option
    mixer: MixerChannel,                // NOT Option
    empty_channel_timer: Option<JoinHandle<()>>,  // Optional because it
                                        // truly can be None within
                                        // Recording (when channel is
                                        // populated).
    dave_heal_consumer: JoinHandle<()>,
    // … fields legitimately always present post-gate
}

struct FinalizingState {
    session_uuid: Uuid,
    // … what finalize needs
}
```

`ActorCore` keeps the phase-invariant stuff (state, ctx, cancel,
buffer_root, obs, participants, packet_routes, session, audio_handle).
Phase-specific stuff lives inside the phase enum.

## Transitions

```rust
impl StabilizingState {
    fn promote(self, uuid: Uuid, mixer: MixerChannel, …) -> RecordingState {…}
}

impl RecordingState {
    fn start_finalize(self) -> FinalizingState {…}
}
```

Transitions **consume** the old state — compile error if anything
tries to read from it after the move. That's the main payoff: the
"old accept-bool-on-StabilizingState-post-gate" bug becomes a type
error, not a runtime bug.

## Risks and how to manage them

1. **Scope blow-up.** `actor.rs` is 2000 LoC. Do it in stages:
   - Stage 1: extract `StabilizingState` only. Keep `RecordingState`
     fields inline on ActorEnv with Options. No behavior change.
   - Stage 2: extract `RecordingState`. Flip the Options to required.
     Run through tests.
   - Stage 3: extract `FinalizingState`. Harder — finalize is the
     messiest path, so save for last.
   - **Do NOT do all three in one PR.**

2. **Heal cycle crosses phases.** `DaveHealRequest` consumer spawned
   during `join_voice_and_attach`, can fire in Stabilizing or Recording.
   Heal path leaves voice → rejoins voice → re-attaches receiver. The
   rejoin happens regardless of phase; so the heal consumer needs
   access to `ActorCore`, not the phase-specific state. Design the
   split so "what does heal need" is clear before writing code.

3. **Command dispatch across phases.** `Stop`, `SetLicense`, `Enrol`,
   `VoiceStateChange`, etc. come in as `SessionCmd` on the mpsc
   channel. Each command needs a different response depending on phase.
   Today: big `match phase { … }` with option-chasing inside. After:
   dispatch on the phase enum, call a phase-specific method. Cleaner,
   but the command enum doesn't change.

4. **Timer churn.** `empty_channel_timer` gets set / cancelled /
   re-set as people come and go. Putting it inside `RecordingState`
   (where it lives logically) means you need mutable access to the
   phase struct while holding `&mut ActorCore`. Needs the right
   destructuring pattern (`match &mut self.phase { ActorPhase::Recording(r) => … }`).

5. **Snapshot rendering.** `SessionSnapshot` is built from actor
   state on every `GetSnapshot` command (harness + tests). The
   snapshot code needs to know the phase and pull the right fields.
   Low risk — single function rewrite.

## What WON'T change

- `SessionCmd` variants and request/response signatures. External
  API is unchanged; all refactor is internal to `session::actor`.
- `Session` model (`session/mod.rs`) — participant state, consent
  logic, etc. That's already a clean domain model.
- `Phase` enum in `session/phases.rs` — already exists, already
  fine. The refactor introduces an inner `ActorPhase` that's richer
  because it holds per-phase state; the outer `Phase` (used in
  `SessionSnapshot` for external observers) stays simple.
- `ParticipantChannel` and `ParticipantCtx` in `session::actor` —
  participant-level state is already encapsulated, it's the
  session-level state that's messy.

## Acceptance

When this refactor is done, the following things become impossible
without a compile error:

- Accessing `mixer` in Stabilizing code paths.
- Accessing `session_uuid` before gate-open.
- Forgetting to move the audio handle into the new phase on transition
  (compiler tracks the move).
- Dropping pending-flush futures on phase transition (has to be
  explicitly drained or moved).

Tests that should still pass unchanged:
- All `session::stabilization` streak-tracker tests.
- All `session::actor::tests` that drive the actor via commands.
- `voice-capture/tests/*` integration tests (harness-driven E2E).

## Timeline

Deferred until OP5/SSRC-mapping (task #64) and Unknown-interaction
(task #65) debugging produces fixes and test coverage. Refactoring
atop an unstable voice-capture path would conflate bugfixes with
restructuring in the diff, making both harder to review.

Rough estimate once unblocked: **1-2 days of focused work per stage**,
assuming all existing tests stay green at each checkpoint.
