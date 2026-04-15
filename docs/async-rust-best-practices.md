# Async Rust Best Practices for `chronicle-*`

A house-style guide for writing async Rust in the chronicle services
(`chronicle-bot`, `chronicle-data-api`, `chronicle-worker`,
`chronicle-pipeline`, `chronicle-feeder`). Audience: a Rust engineer who
already knows ownership, `Send`/`Sync`, `Pin`, futures, and the basic
shape of `.await`. This document is about *what to do*, not *what async
is*.

This doc exists because the recent voice-capture refactor — which moved
the bot from a single `Mutex<State>` to a per-session actor pattern —
surfaced a recurring set of mistakes. Most of them boiled down to one
thing: **independent async work was being serialized by `.await` for no
reason**. The rules below are designed to make that bug class hard to
write.

---

## Table of Contents

1. [Concurrency vs parallelism vs async](#1-concurrency-vs-parallelism-vs-async)
2. [The core rule: don't gate independent work on `.await`](#2-the-core-rule-dont-gate-independent-work-on-await)
3. [Structured concurrency with `JoinSet`](#3-structured-concurrency-with-joinset)
4. [Spawn-and-forget vs spawn-and-join](#4-spawn-and-forget-vs-spawn-and-join)
5. [Locks across `.await`](#5-locks-across-await)
6. [Message-passing as a lock alternative](#6-message-passing-as-a-lock-alternative)
7. [Cancellation](#7-cancellation)
8. [Interaction with frameworks: serenity, axum](#8-interaction-with-frameworks-serenity-axum)
9. [Discord's 3-second rule](#9-discords-3-second-rule)
10. [Channel taxonomy: oneshot, mpsc, broadcast, watch](#10-channel-taxonomy-oneshot-mpsc-broadcast-watch)
11. [Bounded vs unbounded channels](#11-bounded-vs-unbounded-channels)
12. [`Send`, `Sync`, `Arc`, and the spawn boundary](#12-send-sync-arc-and-the-spawn-boundary)
13. [`Pin` and `!Unpin` types in practice](#13-pin-and-unpin-types-in-practice)
14. [Stack-specific anti-patterns](#14-stack-specific-anti-patterns)
15. [Observability for async code](#15-observability-for-async-code)
16. [Smoke tests for these rules](#16-smoke-tests-for-these-rules)

---

## 1. Concurrency vs parallelism vs async

Three terms that get conflated. They mean different things.

- **Async** is a programming model. Functions can suspend at `.await`
  points and yield control back to a runtime. The runtime resumes them
  when whatever they were waiting on is ready. Async by itself buys
  you nothing more than the ability to *interleave* work.
- **Concurrency** is overlapping work in time. Multiple things are
  in-flight at once. Async gives you concurrency on a single thread by
  interleaving suspensions.
- **Parallelism** is overlapping work in space. Multiple things are
  *executing simultaneously* on different CPUs. Async alone does not
  give you this — you get parallelism from `tokio::spawn` (which lets
  the multi-threaded scheduler place work on different worker threads),
  from `rayon`, or from explicit OS threads.

The everyday consequence: writing an `async fn` is not enough.
`async fn` followed by sequential `.await`s buys you exactly zero
concurrency. The compiler emits a state machine that suspends, resumes,
suspends, resumes — but each suspension is gated on the previous result
being ready. To get concurrency you need to construct multiple
in-flight futures and let the runtime interleave them.

> **Note.** Tokio's `#[tokio::main]` defaults to a multi-threaded
> runtime sized to the number of cores. So once you `spawn`, you get
> real parallelism for free — you don't need to opt in to a thread
> pool. The cost is that any spawned future must be `Send + 'static`,
> see §12.

---

## 2. The core rule: don't gate independent work on `.await`

If two async operations don't depend on each other's output, they must
run concurrently. Sequential `.await`s on independent work is the
single most common bug in this codebase, and the easiest one to
prevent.

### The anti-pattern

```rust
async fn handle_record(ctx: &Context, cmd: &CommandInteraction, state: &Arc<AppState>) {
    // BAD: these three calls are independent. Total latency = sum.
    let session = state.api.create_session(...).await?;
    let blocked = state.api.check_blocklist(user_id).await?;
    let guild   = ctx.cache.guild(guild_id).unwrap().clone();
    // ...
}
```

`create_session` and `check_blocklist` both round-trip the data API.
Neither needs the other's result. The cache lookup is sync. With three
sequential awaits the wall-clock time is `t_create + t_check`. With
the right concurrency primitive it's `max(t_create, t_check)`.

### Fix 1: `tokio::join!` for fixed-arity, infallible work

```rust
let guild = ctx.cache.guild(guild_id).unwrap().clone();
let (session, blocked) = tokio::join!(
    state.api.create_session(...),
    state.api.check_blocklist(user_id),
);
```

`join!` polls every future on the *current task*. Both futures
make progress whenever either is suspended. If one panics the other is
dropped at the next suspension point. `join!` does not spawn new tasks
— it does not require `Send` — but it also does not give you
parallelism beyond what one OS thread can provide. Use `join!` when:

- The number of branches is fixed and known at compile time.
- All branches return normally (no `Result`-flavoured short-circuit).
- The branches are CPU-cheap or each waits mostly on I/O.

### Fix 2: `tokio::try_join!` when any error must abort the rest

```rust
let (session, blocked) = tokio::try_join!(
    state.api.create_session(...),
    state.api.check_blocklist(user_id),
)?;
```

Identical to `join!`, except every branch must return
`Result<T, E>` with the same `E`, and the macro short-circuits to the
first `Err`. The remaining futures are dropped. Use `try_join!` when
any failure should preempt the rest — typically setup or fan-out
queries where partial success is useless.

### Fix 3: spawn-and-await for genuine parallelism or `Send`-ful tasks

```rust
let session_fut = tokio::spawn({
    let api = state.api.clone();
    async move { api.create_session(/* ... */).await }
});
let blocked_fut = tokio::spawn({
    let api = state.api.clone();
    async move { api.check_blocklist(user_id).await }
});
let session = session_fut.await??;   // unwrap JoinError, then ApiError
let blocked = blocked_fut.await??;
```

`spawn` puts the future on the executor's task queue. It can run on a
different worker thread than the caller. The caller does not block on
the spawned task until it `.await`s the `JoinHandle`. Use `spawn` when:

- You want true parallelism (the work is CPU-bound or competing for
  I/O wakeups under heavy load).
- The future needs to outlive the caller (fire-and-forget).
- The number of branches is *dynamic* and you'll collect them via
  `JoinSet` (§3) or a `Vec<JoinHandle>`.

### Which to pick

| Situation                                              | Use            |
| ------------------------------------------------------ | -------------- |
| 2–4 independent calls, no errors, fixed at compile     | `join!`        |
| 2–4 independent calls, all return `Result`, fail-fast  | `try_join!`    |
| Dynamic N, want results as they finish                 | `JoinSet`      |
| Dynamic N, just want them all to complete              | `JoinSet` or `Vec<JoinHandle>` + `join_all` |
| Fire-and-forget background work                        | `tokio::spawn` (drop the handle) |
| One call needs to outlive its caller                   | `tokio::spawn` |

> **Gotcha.** `join!` does not parallelize across threads. Two CPU-heavy
> futures inside `join!` will not run on two cores; they will
> cooperatively interleave on one. If the work is CPU-bound use
> `spawn` and accept the `Send + 'static` constraint.

> **Gotcha.** `join!` polls in document order until everything's done.
> If branch 1 always becomes ready instantly but branch 2 takes 5s, the
> macro is still polling branch 1 to completion *before* it starts
> polling branch 2 the first time. If you need fairness use
> `tokio::select!` with the `biased` opt-out, or push to `spawn`.

### Where this shows up in our code

- `chronicle-bot/voice-capture/src/commands/record.rs` —
  `handle_record` does `create_session().await`, then loops over members
  doing `check_blocklist().await` *sequentially*. Five participants is
  five round-trips when it could be one `try_join_all`. Filed as a
  follow-up.
- `chronicle-bot/voice-capture/src/api_client.rs` — `add_participants_batch`
  upserts every user's row sequentially before issuing the batch insert
  (see line 440). The comment calls it out: "small N, not worth
  parallelizing." That's a judgement call you should re-evaluate per
  call site, not a rule.

---

## 3. Structured concurrency with `JoinSet`

When the number of futures is dynamic — N participants, M chunks, K
sessions to drain on shutdown — reach for `tokio::task::JoinSet`. It's
a typed `HashSet<JoinHandle<T>>` with the right semantics for spawning
into the current runtime, awaiting *one at a time as they finish*, and
cancelling the lot on drop.

```rust
use tokio::task::JoinSet;

async fn upload_all_chunks(
    api: Arc<DataApiClient>,
    chunks: Vec<(String, Vec<u8>)>,
) -> Result<(), ApiError> {
    let mut set = JoinSet::new();
    for (pseudo_id, data) in chunks {
        let api = api.clone();
        set.spawn(async move {
            api.upload_chunk_with_retry(session_id, &pseudo_id, data).await
        });
    }
    while let Some(res) = set.join_next().await {
        // First layer: tokio::task::JoinError (panic / cancellation).
        // Second layer: ApiError from the inner future.
        res??;
    }
    Ok(())
}
```

Key properties:

- **Drop is abort-all.** When the `JoinSet` is dropped (e.g. the
  enclosing function returns early on an `?`), every still-running
  task is aborted. This is the structured-concurrency win: the lifetime
  of the spawned tasks is bounded by the lifetime of the set.
- **Order is completion order.** `join_next()` returns whichever task
  finished first. Use `join_next_with_id()` if you need to associate
  the result with a specific input.
- **`abort_all()` does not await.** It signals; tasks may still emit
  one more output. Use `shutdown().await` to abort and wait.
- **Spawn requires `Send + 'static`.** Same constraints as
  `tokio::spawn`. See §12.

### When to prefer `JoinSet` over bare `tokio::spawn`

- You need to *wait* for the work to complete before returning to the
  caller (so you can't drop the handles).
- You want abort-on-error semantics — if the second task fails, the
  first should be cancelled.
- The number of tasks is variable and you don't want to maintain a
  `Vec<JoinHandle<T>>` by hand.

### When `JoinSet` is wrong

- Fire-and-forget logging or notification — that's a bare `spawn`.
- Two or three branches that are fixed at compile time — that's
  `join!` / `try_join!`.
- You need the task to outlive the function — `JoinSet` will abort it
  on drop.

> **Gotcha.** `JoinSet::join_next` returns `Option<Result<T, JoinError>>`.
> `None` means the set is empty. `JoinError` is panic / cancellation,
> *separate* from any `Result` your own future returns. Doubly nested
> `Result` is the norm; the `??` idiom flattens it.

> **Gotcha.** `set.spawn(f)` returns an `AbortHandle` not a
> `JoinHandle`. You can't `.await` it. To wait for a specific task,
> use `join_next_with_id` and store the `Id` it returns from `spawn`.

### Where this shows up in our code

We don't currently use `JoinSet` anywhere in `chronicle-bot`. The
audio-chunk upload path in `voice/receiver.rs` spawns each chunk as a
detached `tokio::spawn` (line 424), which is correct for hot-path
fire-and-forget, but the *finalization* path
(`buffer_task` lines 363–392) flushes per-speaker buffers
**sequentially**. With N speakers that's N serial round-trips on a
path that already has the user waiting. A `JoinSet` would shave most of
the wall-clock latency off `/stop`. Filed as a follow-up.

---

## 4. Spawn-and-forget vs spawn-and-join

`tokio::spawn` always starts the future running. The returned
`JoinHandle` is *just a way to await its output and detect panics*.
Drop the handle and the task continues running until it completes (or
the runtime shuts down). This differs from std threads' `JoinHandle`,
which detaches on drop with the same semantics — but the consequences
in async code are easier to mishandle.

### Spawn-and-forget — when to drop the handle

```rust
// Fire the Data API call asynchronously — caller doesn't care about the result.
let api = state.api.clone();
tokio::spawn(async move {
    if let Err(e) = api.record_consent(sid, user_get, "full").await {
        error!("API call failed (record_consent): {e}");
    }
});
```

This is correct when:

- The caller cannot wait (Discord 3-second window, see §9).
- The work is genuinely fire-and-forget (logging, telemetry,
  notifications).
- The error path is "log and move on" — no caller can do anything
  better.

> **Note.** Always `.clone()` the `Arc` before the `async move`, never
> the underlying object. The `move` block captures the clone, the
> caller keeps the original.

### Spawn-and-join — keep the handle when it matters

If you spawn for parallelism (§2 fix 3), keep the handle and `.await`
it. If you spawn long-lived work that should be aborted at the right
time, store the handle so you can call `abort()` later. Example:

```rust
let cleanup_task = tokio::spawn(async move {
    tokio::time::sleep(Duration::from_secs(14 * 60)).await;
    let edit = EditInteractionResponse::new().components(vec![]);
    let _ = http
        .edit_followup_message(&interaction_token, msg_id, &edit, vec![])
        .await;
});
// Hand cleanup_task to the actor so it can abort the timer if /stop
// fires before the 14-minute mark.
let _ = handle.send(SessionCmd::AddLicenseFollowup {
    token, message_id, cleanup_task,
}).await;
```

That pattern lives in `chronicle-bot/voice-capture/src/commands/consent.rs`
(`send_license_followup`) and the abort happens in
`Session::abort_all_background_tasks`.

### Common spawn-and-forget bugs

1. **Leaked work that should have been aborted.** If you spawn a 30s
   sleep+work loop and never store the handle, you can't cancel it —
   even if the session it belonged to is long gone. Symptom:
   "ghost" Discord messages or background uploads that fire after
   `/stop`. Fix: hand the handle to whoever owns the lifetime
   (typically an actor).
2. **Captured `Arc` outlives the parent's intent.** A spawned task
   holding `Arc<DataApiClient>` keeps the client alive for as long as
   the task runs. If the task is leaked, so is the client. Usually
   harmless, but on shutdown it can prevent a clean exit.
3. **Errors silently dropped.** Spawning then dropping the handle
   means panics inside the future are swallowed unless you set a
   panic hook. Always log inside the spawn block, or `.await` the
   handle and check the `JoinError`.

> **Gotcha.** `tokio::spawn(f).await` does **not** propagate panics.
> The `JoinHandle::await` returns `Result<T, JoinError>` where
> `JoinError::is_panic()` tells you a panic happened — but the panic
> itself is captured, not re-thrown. If you want panic-on-panic you
> need to call `JoinError::into_panic()` and `panic_any` it.

### Where this shows up in our code

- `chronicle-bot/voice-capture/src/main.rs:62-72` — the heartbeat task
  is spawn-and-forget. Correct: it's a daemon for the life of the
  process, no one else owns it.
- `chronicle-bot/voice-capture/src/session/actor.rs:535-546` —
  `do_record_consent` spawn-and-forgets the data-API write. Correct:
  the actor must reply to the click within Discord's window, so it
  can't await the round-trip.

---

## 5. Locks across `.await`

> **Almost every time you hold a lock across an `.await`, it is a bug.**

The mechanic: when an `async fn` suspends at an `.await`, the entire
state of the function is captured in the future and stashed. If you're
holding a `MutexGuard` at that point, the guard goes into the future's
state. The lock stays held *for the entire duration of the suspension*,
including time the runtime spends polling other tasks on the same
worker thread.

This is poison in a multi-task system. Other tasks waiting on the same
mutex queue up. Worse, if the suspended future is itself blocked on
something one of those queued tasks would unblock, you have a deadlock.

### The two mutexes

| Lock | Use when |
| --- | --- |
| `std::sync::Mutex` | Protected data is modified in non-async contexts only. The lock is held briefly (a few hash ops). The `MutexGuard` is `!Send`, so the compiler will reject any attempt to hold it across an `.await`. |
| `tokio::sync::Mutex` | You need to await *while* holding the lock — typically because the protected resource is itself an async-aware client (e.g. a connection that you must hold across a request/response round trip). |

`tokio::sync::Mutex` is *slower* than `std::sync::Mutex` even in the
fast path because it goes through the runtime's wakeup machinery.
Don't reach for it just because you're in async code. Reach for it
only when you actually need to suspend while holding the lock.

### The "don't hold across await" pattern

The standard idiom is to take the lock, mutate, and drop the guard
*before* the next `.await`:

```rust
let new_count = {
    let mut guard = self.users.lock().expect("poisoned");
    guard.insert(user_id);
    guard.len()
}; // <-- guard dropped here

self.api.notify(new_count).await?; // <-- now safe to await
```

The block scope is the common idiom because it makes the guard's
lifetime grammatical. You can also `drop(guard)` explicitly if a block
would be awkward.

### Why `std::sync::Mutex` is the right default

The compiler does the work for you. `std::sync::MutexGuard` is `!Send`,
so it cannot live in any future that's `Send`. Try to write an
`async fn` that holds an `std::sync::MutexGuard` across an `.await`
and you'll get:

```
error: future cannot be sent between threads safely
note: future is not `Send` as this value is used across an await
```

That's a feature. Use `std::sync::Mutex` *unless* you have a documented
reason to use `tokio::sync::Mutex`.

### When `tokio::sync::Mutex` is correct

- The protected resource has its own internal awaits that must run
  sequentially — e.g. a connection whose `read` and `write` can't
  interleave.
- The critical section genuinely needs to await. Reading/mutating an
  in-memory `HashMap` doesn't.

### Where this shows up in our code

- `chronicle-bot/voice-capture/src/voice/receiver.rs:117` —
  `ssrc_to_user: Arc<StdMutex<HashMap<u32, u64>>>`. Correct:
  the VoiceTick hot path holds the guard for one HashMap insert/lookup
  and never awaits. Using `tokio::sync::Mutex` here would add wakeup
  overhead to every audio packet.
- `chronicle-bot/voice-capture/src/voice/receiver.rs:118` —
  `consented_users: Arc<Mutex<HashSet<u64>>>` (tokio mutex). The
  comment at line 242–245 calls out the correct pattern: take the
  *tokio* mutex first (async), then the *std* mutex, so the std guard
  never crosses an await:
  ```rust
  // Acquire the tokio mutex (async) first so the std mutex guard
  // never needs to cross an await point — std MutexGuard is !Send.
  let consented = self.consented_users.lock().await;
  let ssrc_map = self.ssrc_to_user.lock().expect("ssrc_map poisoned");
  ```
- `chronicle-bot/voice-capture/src/session/actor.rs:1281` — `heal_step`
  awaits `data.consented_users.lock().await` *and* holds the guard
  through the next std-mutex acquisition. The guard scope is bounded
  by a small block (`let (...) = { ... };`) to ensure it's dropped
  before any subsequent await. This is the right shape.

> **Gotcha.** `RwLock`'s read/write guards have the same `!Send`
> distinction. `std::sync::RwLock`'s guards are `!Send`,
> `tokio::sync::RwLock`'s are `Send`. Same rule: prefer `std` unless
> you need to await while holding.

> **Gotcha.** `parking_lot::Mutex` is faster than `std::sync::Mutex`
> but its `MutexGuard` *is* `Send`. That defeats the
> "compiler-checked don't-hold-across-await" property. Don't reach for
> `parking_lot` just because it's faster — you'll lose the safety net.

---

## 6. Message-passing as a lock alternative

For per-entity state — a recording session, an order, a connection —
the actor model beats shared-state mutex hands down.

### The shape

```text
                ┌─────────────┐
   handlers ───►│ mpsc inbox  │───► actor task (owns state)
                └─────────────┘            │
                       ▲                   │ each cmd carries
                       │                   │ a oneshot reply tx
                       │                   ▼
                       └───── oneshot::Sender<Reply>
```

The actor owns its state exclusively (it's a `&mut Session` inside one
async function). Mutation is serialized by construction. External
handlers `send` a command and `await` the reply on a oneshot. No locks
anywhere.

This is exactly what we did in the voice-capture refactor. See
`chronicle-bot/voice-capture/src/session/actor.rs` for the canonical
implementation.

### Why this beats `Mutex<State>` for per-entity work

| | `Mutex<HashMap<Guild, Session>>` | Per-guild actor with `DashMap<Guild, mpsc::Sender>` |
| --- | --- | --- |
| Lookup contention | Every operation in any guild contends on one lock. | Lookups are lock-free (dashmap shards). |
| Long operations | A 5-second voice join blocks every other guild's interactions. | One actor's slow path doesn't touch any other actor. |
| Reasoning about state | "Anyone could mutate anything at any await." | "Only this task mutates this struct." |
| Cancellation | Manual `AtomicBool` polling. | Phase transitions, watch channels, drop the handle. |
| Test surface | Hard — must mock the whole `Mutex<State>`. | Easy — pure functions on `&mut Session`, see `actor.rs` test module. |

### Channel sizing and backpressure

```rust
let (tx, rx) = mpsc::channel::<SessionCmd>(64);
```

Bounded. When the buffer fills, `tx.send(cmd).await` *suspends* until
the actor consumes a message. That's backpressure — the producers slow
down. See §11 for why this matters.

### What happens when the receiver drops

`mpsc::Sender::send` returns `Err(SendError(t))` once the receiver is
dropped. The `t` is your message back. Always handle this:

```rust
impl SessionHandle {
    pub async fn send(&self, cmd: SessionCmd) -> Result<(), SessionError> {
        self.tx.send(cmd).await.map_err(|_| SessionError::ActorGone)
    }
}
```

That's the pattern in `actor.rs:240–243`. The handler now has an
explicit "actor is gone" branch and can render an "no active session"
followup.

### What happens when the reply oneshot drops

The actor sends the reply with `let _ = reply.send(...)`. That can
fail if the requester's `Receiver` was dropped (caller went away mid-
operation). The actor must not panic on that.

The flip side — caller waiting on a `oneshot::Receiver` — gets
`Err(RecvError)` if the actor dropped the sender without sending. The
helper in `actor.rs:254–261` collapses both failure modes:

```rust
pub async fn request<T, F>(handle: &SessionHandle, build: F) -> Result<T, SessionError>
where F: FnOnce(oneshot::Sender<T>) -> SessionCmd,
{
    let (tx, rx) = oneshot::channel();
    handle.send(build(tx)).await?;
    rx.await.map_err(|_| SessionError::ActorGone)
}
```

### When *not* to use the actor pattern

- The entity has no internal state of consequence — it's just a
  function with a couple of fields. Then the function is enough.
- The "entity" is the whole program — you'll just be reinventing the
  main loop with extra ceremony.
- Throughput requirements exceed what one mpsc consumer can absorb.
  Per-actor mpsc is sequential by construction; if a single guild's
  workload is too much for a single async task, you've got bigger
  architectural fish to fry.

### Where this shows up in our code

The whole of `chronicle-bot/voice-capture/src/session/actor.rs` — the
actor, its `SessionCmd` enum, the `SessionHandle`, the `request`
helper, the `run_actor` `select!` loop. Read this file before adding
any new long-running per-entity workflow elsewhere in the codebase.

---

## 7. Cancellation

Futures in tokio are abortable: dropping a `JoinHandle` and calling
`.abort()` on it kills the task at its next suspension point. But
**you almost never want to rely on that as your primary cancellation
mechanism**. It's coarse, it can leave external state half-mutated
(no `Drop` runs in the middle of an `.await`), and it's invisible to
the future itself.

The right mental model: cancellation is a *signal that the future
chooses to observe at known points*. The signal usually lives in a
shared structure — a `watch` channel, a `CancellationToken`, or an
`AtomicBool`.

### The two idioms

**`tokio_util::sync::CancellationToken`** is the standard tool. Add
`tokio-util` (we don't depend on it yet — file an issue if you want
it). It supports child tokens, drop-cancellation, and integrates with
`select!`.

```rust
use tokio_util::sync::CancellationToken;

let cancel = CancellationToken::new();

let child = cancel.child_token();
tokio::spawn(async move {
    tokio::select! {
        _ = child.cancelled() => {
            info!("worker_cancelled");
        }
        result = do_work() => {
            // ...
        }
    }
});

// Later, somewhere else:
cancel.cancel();  // wakes every cancelled() future, drops child tokens too
```

**`tokio::sync::watch::channel<bool>`** is what we use today (see
`actor.rs:323`). It's lighter-weight, single-purpose, and adequate
when there's one signaller and the cancellation surface is a single
function:

```rust
let (cancel_tx, _primed) = watch::channel(false);

// In the worker:
let mut watch_rx = cancel_tx.subscribe();
loop {
    tokio::select! {
        biased;
        changed = watch_rx.changed() => {
            if changed.is_err() { return; } // sender dropped
            if *watch_rx.borrow() { return; } // explicitly cancelled
        }
        _ = do_one_iteration() => {}
    }
}

// Elsewhere:
let _ = cancel_tx.send(true);
```

We use the `watch` flavour in
`chronicle-bot/voice-capture/src/session/actor.rs` — the actor owns a
`watch::Sender<bool>`, the startup helper subscribes a receiver, and
the actor flips the bit on `Stop` to preempt the helper between
awaits. See `cancellable_sleep_drain` (line 1009) for the canonical
pattern.

### The critical property

**Futures don't abort on drop unless they themselves check for
cancellation.** A future that's mid-HTTP-request will finish the HTTP
request before suspending again. If your "cancellation" is "drop the
JoinHandle," you're at the mercy of the future's next `.await`.

For a function with several awaits in series, this means: poll the
cancellation signal *between awaits*, or wrap each await in
`select!` with the cancellation branch.

### Polling between awaits

```rust
async fn startup_pipeline(cancel: &CancellationToken) -> Result<(), Preempted> {
    voice_join().await?;
    if cancel.is_cancelled() { return Err(Preempted); }

    dave_handshake().await?;
    if cancel.is_cancelled() { return Err(Preempted); }

    confirm_recording().await?;
    Ok(())
}
```

Cheap, explicit, easy to grep for. Use this when each step is itself
short.

### `select!` with cancellation

When a step is itself a long await, race it against the cancellation:

```rust
tokio::select! {
    biased;
    _ = cancel.cancelled() => Err(Preempted),
    result = slow_dave_handshake() => result.map_err(Into::into),
}
```

`biased;` makes `select!` poll branches in declaration order (default
is random) so the cancellation check is always favored. We use this
pattern in the actor's startup pipeline.

### What a *cancelled* future leaves behind

Dropping an in-flight future runs `Drop` on every value it owns at the
point of suspension (the `MutexGuard`s, file handles, etc.) but does
**not** run any code from the function body — including `defer`-style
cleanup you might have written. If you need post-cancellation cleanup,
do it explicitly after observing the cancellation signal:

```rust
let result = tokio::select! {
    _ = cancel.cancelled() => Err(Preempted),
    r = do_work() => r,
};
cleanup().await; // runs whether we were cancelled or finished
result
```

### Where this shows up in our code

- `chronicle-bot/voice-capture/src/session/actor.rs:1004–1055` —
  `cancellable_sleep_drain` is the canonical example: it sleeps for a
  duration but interleaves with the actor's mpsc and a watch
  cancellation. Returns early if either fires.
- `chronicle-bot/voice-capture/src/session/actor.rs:81` (the
  `Phase` doc comment) — uses *phase transitions themselves* as a
  passive cancellation mechanism. A startup helper checks
  `session.phase` between awaits and bails if it's no longer
  `StartingRecording`. This is the lightest-weight cancellation
  imaginable — no separate signal, just the state machine.

> **Note.** When we add a new long-running background task, default to
> a `CancellationToken` carried into it. Don't add `AtomicBool`s for
> ad-hoc cancellation; we now have three different patterns (watch,
> atomic, phase) and one more would be confusing.

---

## 8. Interaction with frameworks: serenity, axum

### Serenity's `EventHandler` is a bottleneck

Serenity dispatches gateway events by calling your `EventHandler`
methods on the same task that's reading the gateway socket. That call
is `.await`ed before the next event is dispatched. **If your handler
blocks for 200ms, every other event queues for 200ms.**

For interactions that's catastrophic — Discord interaction tokens
expire 3 seconds after the user click (§9), and those 3 seconds start
when Discord sends the event, not when your handler starts running. A
slow handler ahead of yours in the queue eats your budget.

The rule: **every `EventHandler` method should `tokio::spawn` and
return immediately.**

```rust
async fn interaction_create(&self, ctx: Context, interaction: Interaction) {
    let state = self.state.clone();
    tokio::spawn(async move {
        // do the actual work here
    });
    // returns immediately — the gateway loop continues
}
```

The spawn-and-return pattern is wired up in
`chronicle-bot/voice-capture/src/main.rs:72–155` for `interaction_create`,
`voice_state_update`, and any other handler. The `voice_state_update`
case has a particularly informative comment because it was written
*after* a production incident where mid-session voice churn blocked
slash-command interactions.

`ready` is the one exception we treat differently — it runs once at
startup, doesn't have a 3-second budget, and the work it does (slash
command registration) is naturally serial.

### Axum handlers spawn implicitly, but don't share the executor with the gateway

Each axum request runs in its own task (axum spawns it for you). So
the same per-handler considerations as serenity don't directly apply —
but the underlying rule still holds: don't do CPU-bound work in an
async handler. Use `tokio::task::spawn_blocking` for that.

### Where this shows up in our code

- `chronicle-bot/voice-capture/src/main.rs:48–155` — the
  `EventHandler` impl. Every method spawns; the `voice_state_update`
  comment is required reading. Note that `Handler::ready` is the
  exception — it's a one-shot startup hook with no latency budget.
- `chronicle-data-api/src/routes/ws.rs` — the WebSocket handler is a
  long-running per-connection async function. It uses `select!` to
  handle three concurrent inputs (incoming client messages, outgoing
  events from a private mpsc, ping interval) without spawning extra
  tasks for each input. Worth studying as an example of "one task,
  multiple concurrent inputs via `select!`."

---

## 9. Discord's 3-second rule

Discord allows exactly 3 seconds between the user's click and your
first response (`create_response`). If you don't ack in that window,
the interaction token is dead — you can't even render an error.
Discord's user sees "This interaction failed."

The user-visible failure mode is invisible to your logs unless you're
specifically looking for it. The next thing that goes wrong is
"Unknown interaction" errors when you try to edit the response after
the token has expired.

### Ack first, then everything else

The pattern: the very first network call in your handler is the ack.

```rust
async fn handle_record(...) -> Result<(), serenity::Error> {
    // Defer IMMEDIATELY. Buys 15 minutes.
    command
        .create_response(
            &ctx.http,
            CreateInteractionResponse::Defer(
                CreateInteractionResponseMessage::new().ephemeral(true),
            ),
        )
        .await?;

    // ... now do real work, even if it takes 30 seconds ...

    command
        .edit_response(
            &ctx.http,
            EditInteractionResponse::new().content("done"),
        )
        .await?;

    Ok(())
}
```

The `Defer` response signals "I'm working on it" to Discord. The user
sees "thinking…" for up to 15 minutes. After the work is done, you
`edit_response` to replace the placeholder with your actual reply.

For component interactions (button clicks) where you don't need to
post a placeholder, use `CreateInteractionResponse::Acknowledge` —
type 6 `DEFERRED_UPDATE_MESSAGE`. It's the lightest possible ack.

### What to *not* do before the ack

**Anything that can block.** Specifically:

- Don't acquire a contended lock. If another task holds it through a
  long await, you queue.
- Don't `.send().await` to an mpsc that might be full. The actor's
  inbox is bounded (64); under load it can briefly fill.
- Don't issue a Data API call. The round-trip to localhost is fast,
  but a 401 + reauth is not.
- Don't read the cache *with a guard you'll hold while you await*. The
  cache lookup itself is fine; holding the lock across an await isn't.

### What to do before the ack

- Cheap synchronous parsing (custom_id matching, enum dispatch).
- Read `state.sessions.get(&guild_id)` — `dashmap` is lock-free per
  shard.
- Check `entry.is_shutting_down()` (atomic load).

### Where this shows up in our code

- `chronicle-bot/voice-capture/src/commands/record.rs:43–58` —
  `handle_record`'s `Defer` is the very first awaited call.
- `chronicle-bot/voice-capture/src/commands/consent.rs:62–64` —
  `handle_consent_button`'s `Acknowledge` is the very first awaited
  call. Comment at lines 57–61 explicitly justifies the ordering vs
  the actor's mpsc queue.
- `chronicle-bot/voice-capture/src/commands/license.rs:46–48` — same
  pattern for license toggle clicks.

> **Note.** The 3-second budget is per-interaction, not per-process.
> If you're handling 100 concurrent button clicks, each one has its
> own 3-second window, and they're independent — but only because
> we spawn each into its own task. Without the spawn-on-entry pattern
> in §8, they would queue serially behind the gateway loop.

---

## 10. Channel taxonomy: oneshot, mpsc, broadcast, watch

Tokio gives you four channel flavors. Pick the one that matches your
delivery semantics.

### `oneshot` — one value, one consumer, one producer

```rust
let (tx, rx) = oneshot::channel::<MyReply>();
spawn_actor_with(tx);
let reply = rx.await?;
```

Use for **request/reply**. The reply is an `enum`-able single value;
the receiver awaits exactly once. Sender dropping without sending
gives the receiver `RecvError`.

This is what every `SessionCmd::*` variant carries as its `reply:
oneshot::Sender<...>` field.

### `mpsc` — multi-producer, single-consumer, FIFO queue

```rust
let (tx, mut rx) = mpsc::channel::<Cmd>(64);  // bounded
let (tx, mut rx) = mpsc::unbounded_channel::<Cmd>();  // avoid
```

Use for **work queues** and **actor inboxes**. `send().await`
backpressures when full (bounded variant only — see §11).
Cloneable senders.

This is the actor inbox (`SessionCmd` over `mpsc::Sender<SessionCmd>`)
and the audio pipeline (`AudioPacket` from VoiceTick into the buffer
task).

### `broadcast` — multi-producer, multi-consumer, every consumer sees every value

```rust
let (tx, _) = broadcast::channel::<Event>(1024);
let mut rx1 = tx.subscribe();
let mut rx2 = tx.subscribe();  // independent subscription
tx.send(event)?;  // both rx1 and rx2 will receive
```

Use for **pub-sub**. Slow consumers get `RecvError::Lagged` if they
fall behind the buffer; the channel does *not* slow producers down to
keep slow consumers in sync.

We use this in `chronicle-data-api/src/events.rs` for the API event
bus — every WebSocket connection subscribes its own receiver and
filters by topic. The 1024-message buffer is "generous" (per the
comment); a slow client gets a `Lagged` error and the per-connection
drain task either logs and continues or disconnects.

### `watch` — multi-producer, multi-consumer, only the latest value

```rust
let (tx, mut rx) = watch::channel::<Config>(initial);
tx.send(new_config)?;       // overwrites previous
let cur = rx.borrow().clone();  // synchronous read of latest
rx.changed().await?;        // wait for next change
```

Use for **state updates** where intermediate values can be coalesced
— config reloads, "is the system running?" flags, "current term" in
a leader-election protocol. New subscribers see the current value
immediately.

This is exactly the cancellation pattern in
`chronicle-bot/voice-capture/src/session/actor.rs` — a
`watch::Sender<bool>` whose only state is "should startup bail?"

### When to pick which

| Need | Channel |
| --- | --- |
| Function-local "give me back one result" | `oneshot` |
| Actor inbox / work queue | `mpsc` (bounded) |
| One event, many fan-out consumers | `broadcast` |
| Latest snapshot of a piece of shared state | `watch` |
| Wake one task from another (no value) | `tokio::sync::Notify` |

> **Gotcha.** `oneshot::Sender` cannot be cloned. You get exactly one
> reply per channel. To return multiple values, return a `Vec` or
> use `mpsc`.
>
> `broadcast::Receiver` doesn't implement `Clone` (each `subscribe()`
> returns a new one with its own backlog). `watch::Receiver` does
> implement `Clone` and shares position.

---

## 11. Bounded vs unbounded channels

**Default to bounded. Always.** Unbounded channels are a footgun in
production — they trade *bug-now* for *crash-later*, which is strictly
worse.

### What "bounded" actually does

```rust
let (tx, rx) = mpsc::channel::<Cmd>(64);
```

When the buffer holds 64 unconsumed messages, `tx.send(cmd).await`
*suspends* until the consumer drains one. The producer waits. That's
backpressure. The system's natural rate is the consumer's rate.

When you size the buffer too small, you suspend producers
unnecessarily — they spend time waiting instead of working. When you
size it too large, you absorb more bursts but also delay the moment
where backpressure kicks in. A bound of 64 is a fine starting point
for an actor inbox in this codebase.

### What "unbounded" actually does

```rust
let (tx, rx) = mpsc::unbounded_channel::<Cmd>();
```

`tx.send(cmd)` is *synchronous* — it returns `Ok(())` instantly. The
queue grows. If your producers are faster than your consumers, the
queue grows without limit. Memory grows. Eventually the OOM killer
intervenes.

Unbounded channels look attractive in tight loops because there's no
`.await` and the API is easy. They're almost always wrong for
production data paths.

### When unbounded is *actually* OK

- The producer rate is provably bounded by some external clock (e.g.
  one message per 30s heartbeat). You will never produce faster than
  the consumer can drain.
- The producer can never block (e.g. a synchronous callback from
  songbird's event loop) and you absolutely cannot drop or backpressure
  — you'd rather risk OOM than lose data. Even then, prefer
  `try_send` on a generously-sized bounded channel and log if you
  drop.

### What backpressure looks like in practice

Consider a busy guild that just had everyone click "consent" within
50ms of each other:

- The actor inbox is bounded at 64.
- The consent button handler does `handle.send(SessionCmd::RecordConsent
  { ... }).await`.
- If the actor is busy (say, processing a `VoiceStateChange` that's
  doing a Data API blocklist check), the inbox can fill briefly.
- The Nth handler's `send().await` suspends.
- The handler is in a `tokio::spawn`'d task (per §8), so the gateway
  loop continues.
- Meanwhile the user's interaction *has already been ack'd* (per §9),
  so Discord is happy.

That's correct behaviour: producers slow down when the consumer is
saturated, and the system recovers. Unbounded would keep accepting
the `send`s forever — until something else broke.

### The deadlock you must understand

```rust
// Inside the actor:
let result = self.api.send(WorkUnit { reply: rx_for_actor }).await;
// ^ awaits a reply via a channel WHOSE SENDER IS THE ACTOR'S OWN STATE
```

If the reply channel is the *same* mpsc the actor is consuming from,
you've deadlocked. The actor is suspended waiting for the reply, but
the reply can only be sent by the actor processing the next message,
which it can't because it's suspended.

This is rare but easy to write by accident. The cure is to use
`oneshot` for replies and to avoid sending into one's own inbox.

### Where this shows up in our code

- `chronicle-bot/voice-capture/src/session/actor.rs:281` —
  `mpsc::channel::<SessionCmd>(64)`. Bounded; 64 is fine for per-guild
  actor traffic.
- `chronicle-bot/voice-capture/src/voice/receiver.rs:135` —
  `mpsc::channel::<AudioPacket>(1000)`. Bounded; 1000 is sized for
  burst absorption in the audio hot path. The producer (`VoiceTick`)
  uses `try_send` (line 294) so it never suspends in the songbird
  callback — packet drops are acceptable, hot-path suspension is not.
- `chronicle-bot/voice-capture/src/voice/receiver.rs:469` —
  `op5_tx: mpsc::UnboundedSender<Op5Event>`. Unbounded. The producer
  is OP5 from songbird's event loop (rare events, rate-limited by
  Discord). Acceptable per the criterion above. Worth migrating to
  bounded with `try_send`-and-log if it ever turns into a bug.
- `chronicle-data-api/src/routes/ws.rs:149` — `mpsc::channel(1000)`
  per-connection drain queue. Bounded. Slow clients backpressure the
  drain task, which then backpressures against the broadcast bus's
  receiver — clean.

---

## 12. `Send`, `Sync`, `Arc`, and the spawn boundary

The `tokio::spawn` signature:

```rust
pub fn spawn<F>(future: F) -> JoinHandle<F::Output>
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
```

Two requirements: `Send` (the future can move between worker threads)
and `'static` (no borrowed references). These constraints propagate to
everything captured by the future.

### `Send`

A future is `Send` if every value it owns at every suspension point is
`Send`. `Arc<T>` is `Send` if `T: Send + Sync`. `Rc<T>` is `!Send`
(period). `RefCell<T>` is `!Send`. `MutexGuard<T>` from `std::sync` is
`!Send`. From `tokio::sync` it is `Send`.

If your spawned future fails to compile with `future cannot be sent
between threads safely`, the error message will tell you which value
is the offender. Almost always it's one of:

- An `Rc<T>` — switch to `Arc<T>`.
- A `RefCell<T>` — switch to `Mutex<T>` (std or tokio).
- A `std::sync::MutexGuard` held across an await — drop it before the
  await (§5).

### `'static`

The future cannot borrow from anything outside itself. In practice
this means: every captured variable is owned, not a reference. The
standard idiom:

```rust
let api   = state.api.clone();        // Arc clone — cheap
let user  = user_id;                  // Copy
let scope = scope_str.to_string();    // owned String

tokio::spawn(async move {
    api.record_consent_by_id(user, &scope).await
});
```

Note: clone the `Arc`s *before* the `async move` block. The block
captures by move; if you write `state.api.clone()` *inside* the block,
you're cloning an `Arc` that the block is moving — which won't
compile because the block hasn't moved it yet at the call site.

### Three patterns you'll write a hundred times

**Spawn-with-shared-state:**

```rust
let api = state.api.clone();
tokio::spawn(async move { api.do_thing().await });
```

**Spawn-with-multiple-handles (move both, clone both):**

```rust
let api    = state.api.clone();
let ctx    = ctx.clone();
let user   = user_id;
tokio::spawn(async move {
    let _ = api.do_thing(user).await;
    let _ = ctx.http.notify_channel(...).await;
});
```

**Detached spawn from inside an `EventHandler`:**

```rust
async fn voice_state_update(&self, ctx: Context, old: Option<VoiceState>, new: VoiceState) {
    let state = self.state.clone();
    tokio::spawn(async move {
        voice::events::handle_voice_state_update(ctx, old, new, state).await;
    });
}
```

That's literally `chronicle-bot/voice-capture/src/main.rs:141–155`.

### When `Rc<RefCell<T>>` is the right call (it usually isn't)

Within a single async task that's pinned to one thread, `Rc` and
`RefCell` are fine and lighter-weight than `Arc<Mutex<T>>`. You see
this in `tokio::task::LocalSet`-based code and in single-threaded
runtimes. We don't use either; default to `Arc` everywhere and never
think about it.

### Where this shows up in our code

- `chronicle-bot/voice-capture/src/main.rs:84-112` — the canonical
  spawn pattern in `interaction_create`: clone state and command name
  outside the move, then `tokio::spawn(async move { ... })`.
- `chronicle-bot/voice-capture/src/state.rs:14-30` — `AppState`
  contains `Arc<DashMap<...>>` and `Arc<DataApiClient>`. Holders of
  `&Arc<AppState>` clone the inner `Arc`s into spawned tasks.

---

## 13. `Pin` and `!Unpin` types in practice

Most async code does not require thinking about `Pin` directly. The
compiler generates `Future` impls that handle pinning for you, and
`Box::pin` covers the rest.

You'll hit pin errors in three situations:

### 1. Storing a heterogeneous future in a struct

```rust
struct MyHandler {
    work: Pin<Box<dyn Future<Output = ()> + Send>>,
}
```

You need `Pin<Box<dyn Future>>` because you can't name the concrete
async-block type. `Box::pin(async move { ... })` is the constructor.

### 2. Returning an async value from a trait method

```rust
trait Worker: Send + Sync {
    fn run(&self) -> Pin<Box<dyn Future<Output = ()> + Send + '_>>;
}
```

This is the "manual `async_trait`" pattern, used in
`chronicle-worker/src/worker.rs` for `PipelineRunner`. As of 2024
async fn in traits is stable, so prefer:

```rust
trait Worker: Send + Sync {
    async fn run(&self);
}
```

…unless you need object safety (`dyn Worker`), in which case the
boxed-future pattern is still the workaround.

### 3. Holding self-referential futures across an await

The compiler generally prevents you from doing this — that's what
`!Unpin` is for. If you hit a `cannot move out of` error inside an
async fn, you've probably constructed a self-referential structure
(e.g. a future that holds a reference to data also stored in the same
future). Wrap the offender in `Box::pin` and the compiler can keep
its place stable.

> **Note.** You'll write `Box::pin` maybe twice a year on this
> codebase. Don't pre-emptively scatter it everywhere; only reach for
> it when the compiler tells you to.

---

## 14. Stack-specific anti-patterns

Cataloging the per-dependency cliffs.

### `sqlx::PgPool` — clone, don't lock

`PgPool` is internally `Arc<...>`-y. It's already a shared connection
pool. **Cloning is cheap.** Wrapping it in a `Mutex<PgPool>` is wrong
twice over: it serializes connection acquisition (defeating the pool)
and adds latency to every query.

```rust
// Correct:
async fn handler(pool: PgPool) {
    sqlx::query("...").execute(&pool).await?;
}

// Wrong:
async fn handler(pool: Arc<Mutex<PgPool>>) {
    let pool = pool.lock().await;
    sqlx::query("...").execute(&*pool).await?;
}
```

`chronicle-data-api/src/auth/mod.rs` and the rest of the data-api take
`PgPool` by value or borrow it directly. Follow that pattern.

### `reqwest::Client` — one per program, clone for spawn

`reqwest::Client` is internally arc-shared and reuses connections. You
want exactly one per program (one connection pool, shared keepalives)
— and each spawn clones the handle.

```rust
// Correct (and what we do):
pub struct DataApiClient {
    client: reqwest::Client,
    // ...
}

impl Clone for DataApiClient { /* via `#[derive]` or hand impl */ }

// Or in practice:
let api = state.api.clone();   // state.api is Arc<DataApiClient>
tokio::spawn(async move { api.do_thing().await });
```

We construct the `DataApiClient` once in `main()`
(`chronicle-bot/voice-capture/src/main.rs:191-201`) and stash it in
`Arc<DataApiClient>` inside `AppState`. Every spawn clones the `Arc`,
not the underlying client.

### `serenity::http::Http` — held via `ctx.http`, cheap to clone

`ctx.http` is `Arc<Http>`. Clone freely. Hand it to spawned tasks the
same way as any other `Arc`. The actual `Http` struct contains the
shared `reqwest::Client`, so you get the same connection-pooling
benefits.

```rust
let http = ctx.http.clone();
tokio::spawn(async move {
    let _ = http.edit_followup_message(&token, msg_id, &edit, vec![]).await;
});
```

### `songbird::Call` — hidden `Arc<Mutex<Call>>`, careful with the inner mutex

`Songbird::join` returns `Arc<Mutex<Call>>`. Calling `.lock().await` on
that `Arc` gives you a tokio `MutexGuard<Call>`. **Dropping that guard
matters more here than anywhere else in the codebase.**

The `Call` is shared across:

- Your code (joining, leaving, attaching event handlers, playing
  inputs).
- Songbird's internal driver (which may also need to lock to update
  state from voice events).
- Other tasks in your code that have cloned the `Arc`.

If you hold the guard across a long await — e.g. an HTTP call — every
other task waiting on the call deadlocks behind you. Even worse, the
driver's reaction loop can stall, which surfaces as DAVE
(audio-decryption) failures because heartbeats and packet processing
both want the lock.

```rust
// Correct (from actor.rs):
{
    let mut handler = call.lock().await;
    let source = songbird::input::File::new("/assets/recording_started.wav");
    let _ = handler.play_input(source.into());
    drop(handler);                                  // release before sleeping
    tokio::time::sleep(Duration::from_secs(2)).await;
}

// Wrong:
let mut handler = call.lock().await;
let source = songbird::input::File::new("/assets/recording_started.wav");
let _ = handler.play_input(source.into());
tokio::time::sleep(Duration::from_secs(2)).await;  // STILL HOLDING THE LOCK
drop(handler);
```

### Blocking calls (`std::fs`, sync HTTP) inside async — must use `spawn_blocking`

`std::fs::read_to_string`, `std::process::Command::output`, anything
sync that does I/O — these block the *worker thread*. A single
blocking call can stall every other task scheduled to that thread.
Tokio's default scheduler has a fixed number of worker threads (== num
cores); a few blocking calls and the scheduler is starved.

The escape hatch is `tokio::task::spawn_blocking`. It moves the
closure to a separate thread pool dedicated to blocking work
(`blocking_thread_pool`, defaults to 512 threads).

```rust
let result = tokio::task::spawn_blocking(move || {
    // sync code here — std::fs, sync DB drivers, CPU-bound math
    expensive_thing(input)
})
.await
.expect("blocking task panicked")?;
```

`chronicle-pipeline/src/streaming.rs:193` and `vad/mod.rs:75` are the
canonical examples in this codebase — both wrap CPU-intensive VAD
inference in `spawn_blocking` because the underlying ONNX runtime
spawns its own threads and would compete with tokio's worker pool if
called directly.

> **Gotcha.** `spawn_blocking` returns a future you must `.await`.
> Forgetting to await it means the work runs but you don't see its
> result; the blocking task itself isn't aborted by the call site
> (same as bare `spawn`).

> **Note.** Don't use `spawn_blocking` for "I want to run sync code on
> a thread for parallelism." Use `rayon` for that — `spawn_blocking`'s
> pool is sized for "many threads waiting on syscalls," not "few
> threads doing CPU work."

### `tracing::Subscriber` initialization — exactly once

`tracing_subscriber::fmt().init()` panics if called twice. Don't call
it from library code; it's a binary's responsibility. We initialize it
in each binary's `main()`.

---

## 15. Observability for async code

Async code is harder to debug than sync code because work fans out
across tasks and the call stack at the moment of failure isn't
representative of how you got there. The fix is structured logging
with span propagation.

### `#[tracing::instrument]` on every public async fn

```rust
#[tracing::instrument(
    skip_all,
    fields(
        guild_id = component.guild_id.map(|g| g.get()),
        user_id = %component.user.id,
    )
)]
pub async fn handle_consent_button(...)
```

`#[instrument]` opens a span when the function is entered and closes
it on return. Every `info!` / `warn!` / `error!` inside the function
(or any function it awaits) gets the span attached automatically. When
you ship the logs to Grafana / Loki / your tool of choice, you can
filter by `guild_id=X` and see the full sequence of work for one
session across all tasks.

`skip_all` means "don't try to debug-print every argument" — useful
when arguments include `Context` or `&AppState`. Add explicit
`fields(...)` for the IDs you actually want.

### Span propagation across `spawn`

Spawned tasks **don't** inherit spans by default. You have to attach
them explicitly:

```rust
use tracing::{info_span, Instrument};

let span = info_span!("session_actor", session_id = %session_id, guild_id = guild_id);
tokio::spawn(run_actor(state, ctx, session, rx, shutting_down).instrument(span));
```

That's `actor.rs:300-305`. Without `.instrument(span)`, logs from
inside the actor would have no parent span and you'd have to
reconstruct the call chain by hand.

### Why work-fanout makes IDs essential

When `handle_record` spawns three Data API calls in parallel and one
fails, the error log is in a different task than the handler. Without
a session ID attached you can't correlate the failure to the user
action.

The rule: every long-lived task gets at minimum a *session ID*, *guild
ID*, or whatever the natural correlation key is. Add it as a field in
the span; every log line gets it for free.

### `tracing::info_span!` vs structured fields on log lines

Both work. `info_span!` opens a span that nests; fields on log lines
don't. Spans give you "everything that happened during the X
operation"; fields give you "this one log line is about X." Use spans
for *operations* (commands, requests, sessions). Use fields for
*facts* (latency, count, status).

### Where this shows up in our code

- `chronicle-bot/voice-capture/src/commands/record.rs:31` — `#[instrument]`
  on `handle_record`, with `guild_id` extracted into the span.
- `chronicle-bot/voice-capture/src/session/actor.rs:300-305` —
  `info_span!` + `.instrument(span)` on the actor task.
- `chronicle-bot/voice-capture/src/main.rs:79-90` — manual log lines
  with `interaction_id`, `command`, `spawn_delay_us`. Useful here
  because the spawn boundary creates a measurable handoff.

> **Note.** Don't pre-emptively `#[instrument]` every internal helper.
> Small pure functions called many times per millisecond would drown
> the log. Instrument at the *operation* boundary — public async fns
> on the handler/api boundary, the actor's command dispatch, the
> startup pipeline.

---

## 16. Smoke tests for these rules

### What `cargo clippy` catches

Run `cargo clippy --all-targets --all-features -- -D warnings` in CI.
The relevant lints:

- **`clippy::await_holding_lock`** — flags `std::sync::MutexGuard` /
  `RwLockGuard` held across an `.await`. False negatives: doesn't
  catch tokio mutex (but those are *supposed* to be held across awaits
  sometimes), and doesn't catch transitive holds.
- **`clippy::await_holding_refcell_ref`** — same, for `RefCell::borrow`.
- **`clippy::let_underscore_future`** — warns on `let _ = some_future();`
  where the future is dropped without polling. Catches the bug where
  you forgot a `.await`.
- **`clippy::large_futures`** — warns on huge async fn state machines
  that should be `Box::pin`'d.
- **`clippy::needless_pass_by_value`** — sometimes flags `Arc<T>`
  taken by value when `&Arc<T>` would do.

What it *does not* catch:

- Independent async work serialized with `.await` (the §2 anti-pattern).
- Spawned tasks that should have been joined.
- Unbounded channels.
- Locks-across-await on `tokio::sync::Mutex` (the docs say "hold
  across an await is fine"; clippy can't tell which holds are bugs).
- Discord 3-second-rule violations.
- Missing `.instrument(span)` on spawned tasks.

### Manual review cues

When reviewing async code, search for:

- `\.lock\(\).*\n.*\.await` — a tokio mutex acquisition followed
  closely by an await. May be fine (the await is for the protected
  resource itself); may be a held-across-await bug. Read the block
  scope carefully.
- `tokio::spawn` without a stored `JoinHandle` — confirm it's
  intentional fire-and-forget, not leaked work.
- `mpsc::unbounded_channel` — confirm the producer rate is
  externally bounded.
- `\.await\?;.*\n.*\.await\?;` repeated — independent awaits in a
  row. Could be a `try_join!` opportunity.
- Any new `EventHandler` method that doesn't open with
  `let state = self.state.clone(); tokio::spawn(async move { ... });`
  — gateway loop blocker.
- New slash command handlers — first awaited call must be an ack
  (`Defer` or `Acknowledge`), not a state lookup or an API round trip.

### The reviewer's checklist

1. Does every `EventHandler` method spawn?
2. Does every interaction handler ack first?
3. Is every channel bounded?
4. Are all spawned tasks either stored in a structure that can
   `abort()` them, or genuinely fire-and-forget with logging?
5. Are independent awaits parallelized with `join!` / `try_join!` /
   `JoinSet` / spawn?
6. Is every shared state access either lock-free (dashmap, atomic) or
   actor-mediated (mpsc)?
7. Is every long-running future cancellation-aware (poll a token or
   check a phase between awaits)?
8. Are spawned tasks `.instrument(span)`'d with a correlation ID?

---

## Appendix: pre-existing follow-ups identified during this writeup

- `commands/record.rs::handle_record` — sequential `check_blocklist`
  per participant. Worth a `try_join_all` or a `JoinSet`.
- `api_client.rs::add_participants_batch` — sequential `upsert_user`
  before the batch insert. The comment notes "small N"; revisit if
  large parties become common.
- `voice/receiver.rs::buffer_task` flush loop — sequential per-speaker
  upload at finalization. `JoinSet` would shave latency off `/stop`.
- `voice/receiver.rs::op5_tx` — currently an unbounded channel.
  Acceptable today (rare events) but should migrate to bounded with
  `try_send`-and-log if the volume ever changes.
- We don't depend on `tokio-util`. If we adopt `CancellationToken` as
  the standard cancellation primitive (recommended in §7), add the
  dep.
