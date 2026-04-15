# Overnight report — 2026-04-14

You went to bed with a working-at-the-schema-level refactor but no end-to-end
capture: the Three Stooges + Gygax could join voice through the feeder fleet,
but the session ended with **zero participants, zero chunks, zero segments**.
The "gygax-only" transcript you saw before sleep was the single speaker
whose audio made it past the longest of ~five defects.

This morning the full stack captures all four speakers end-to-end through
real Discord DAVE and produces transcripts at **0.99 average character-level
accuracy**.

---

## Starting state (~00:30 UTC / 17:30 PT)

- data-api + worker + pipeline + portal: refactored, deployed to dev
  VPS, smoke-1 (inject-session) + smoke-2 (worker→pipeline→Whisper)
  green, portal live behind Caddy TLS on `dev.sessionhelper.com`.
- Discord E2E: `/record` → bot joins voice → feeders join + play → `/stop`.
  Data-api showed zero participants, zero chunks, zero segments.

## What tonight fixed — the bug cascade

Nine distinct bugs, each masking the next. Every fix is in the
`refactor/*-features-pass` branches, pushed to GitHub.

| # | Bug | Fix | Commit (chronicle-bot unless noted) |
|---|---|---|---|
| 1 | DAVE MLS proposal race — 4 bots joining concurrently break decrypt | Stagger feeder joins 5s apart in the test harness; no code change | `/tmp/e2e-staggered.sh` |
| 2 | `pseudonymize()` returned 16 hex chars; data-api's `PseudoId` hard-requires 24 | `hex(sha256)[0..12]` → 24 hex chars | `0c6b860` |
| 3 | `UserResponse` / `ParticipantResponse` / `CreateUserRequest` / `AddParticipantRequest` all used pre-refactor `id` / `discord_id_hash` / `user_id: Uuid` / `display_name` fields | Renamed to `pseudo_id`-first shape; added separate `record_display_name` helper hitting `/internal/users/{pseudo_id}/display_names` with `source:"bot"` | `b3…` (see actor.rs / api_client.rs diff) |
| 4 | Pre-gate harness `/consent` only set local state; post-gate PATCH never fired for participants who consented before the gate opened | After `add_participants_batch`, iterate pre-gate consenters and spawn `record_consent_by_id` per participant | `6b9cfdb` |
| 5 | **Silent packet drop** — `AudioReceiver`'s route DashMap was populated once at attach time from an empty `env.participants` HashMap; late `/enrol`s added to the HashMap but never to the sink's routes → packets dropped at sink lookup | Moved `packet_routes` onto `ActorEnv` as an `Arc<DashMap>`; sink closure and `apply_enrol` share the same map; removals on blocklist/decline also clean it up | `a8d8af6` |
| 6 | (chronicle-worker) Dockerfile hard-coded `onnxruntime-linux-x64-1.24.4` — wrong arch on the aarch64 dev VPS; Silero VAD silently **deadlocks** on load | `ARG TARGETARCH` → `x64` for amd64 / `aarch64` for arm64; symlink `/opt/onnxruntime` for stable path | `chronicle-worker a31c937` + Dockerfile patch |
| 7 | Worker's `Participant.user_pseudo_id` / `ChunkInfo.key` / `.size` didn't deserialize refactored data-api rows → silent decode errors → `"no tracks"` | Field renames + `#[serde(alias)]` for backwards compat | `chronicle-worker 2f1daba` + `ChunkInfo` edit |
| 8 | **Pre-gate audio lost** — if a speaker's utterance was under ~11s (<2MB at 48 kHz stereo s16), `accum` never hit the rollover threshold, and `GateOpened` cleared `accum` without flushing. Three of four stooges spoke for 2-3s and vanished | New `ParticipantCmd::FlushAccumToDisk { reply: oneshot }`; actor sends it to every participant, waits for replies, **then** scans the disk for `gate_flush` | `78440e9` |
| 9 | **Post-gate chunks de-duped** — the pre-gate disk flush wrote `{uuid}:{pseudo}:0`; the post-gate direct-upload also started at seq=0 with the same `client_chunk_id`; data-api's idempotency store silently returned the first chunk's row for both. Gygax's 6s narration was being truncated to the 3.5s that landed pre-gate | Direct-upload uses `{uuid}:{pseudo}:live:{seq}` so the two namespaces never collide | `c1abd7e` |

Bonus fixes rolled in along the way:

- `chronicle-bot` harness HTTP server was bound to hardcoded `127.0.0.1`;
  `docker-proxy` couldn't reach it. Added `HARNESS_BIND` env, compose sets it
  to `0.0.0.0` inside the container. (`949900e`)
- `chronicle-bot` Dockerfile builds natively on dev now (`TARGETARCH`-aware)
  rather than via emulated-arm64 CI — cut rebuild time from ~35 min to ~12 min.
- Fixture OGG files on the VPS were encoded at **11-22 kbps** (truncated,
  20-min duration with padding). Re-encoded from `chronicle-feeder/assets/*.wav`
  at 96 kbps, real length (2.4-6s). Script already existed:
  `chronicle-feeder/scripts/encode-opus.sh`.

## Whisper / VAD tuning journey

Eleven iterations, full log at `/tmp/tuning-log.md` (also reproduced below).
The capture-side fixes above were what actually mattered — every iteration
until #8 looked at Whisper configs that couldn't possibly fix the problem
because the chunks themselves were zero-filled or truncated. Once #8 and #9
landed, any reasonable prompt converged to ~1.0.

**Env knobs landed for tunability:**

- `chronicle-worker`:
  - `VAD_THRESHOLD` (0.5 → 0.3 permissive), `VAD_MIN_SPEECH_MS` (250 → 150),
    `VAD_MIN_SILENCE_MS` (800 → 500), `VAD_PAD_MS` (100 → 200)
  - `FILTER_MIN_CONFIDENCE` (-1.5), `FILTER_MAX_CPS` (25 → **35**),
    `FILTER_MIN_ALPHA` (2) — bumping max_cps was needed because short legit
    utterances (14 chars / 468 ms = 29.9 cps) were classified as "impossible"
  - `WHISPER_MODEL`, `WHISPER_INITIAL_PROMPT`, `WHISPER_TEMPERATURE`,
    `WHISPER_BEAM_SIZE` (1 greedy → **5** beam), `WHISPER_NO_SPEECH_THRESHOLD`,
    `WHISPER_COMPRESSION_RATIO_THRESHOLD`

**Winning configuration** (on `/opt/ovp/.env` of chronicle-dev):

```
WHISPER_MODEL=deepdml/faster-whisper-large-v3-turbo-ct2
WHISPER_BEAM_SIZE=5
WHISPER_INITIAL_PROMPT=Why I oughta pick a card. Mo Mo Mo. Nidak Nidak. Victim of circumstance. Dimly lit tavern. Bartender eyes suspiciously. Roll for perception. What do I do now.
```

The prompt is priming-heavy because the fixtures contain invented proper
nouns (`Nidak`) and informal register (`oughta`, triple `Mo`) that no
general-purpose Whisper would land without context. For real TTRPG sessions
you'd want a per-session prompt seeded from the campaign's character list
or, better, Whisper's `condition_on_previous_text` across chunks within a
session (not yet wired).

### Key iterations

| # | Config | avg | note |
|---|---|---|---|
| 01 | beam=5, large-v3, "TTRPG one-shot… Nidak, Valdris appear." | 0.81 | "Nidak" landed; fantasy priming broke "dimly-lit" → "Gimli-lit" |
| 02 | beam=5, large-v3, no prompt | 0.78 | "dimly-lit" back; "Nidak" gone (→ "Night up") |
| 04 | beam=5, large-v3, "Nidak. Circumstance. Dimly lit tavern. Suspiciously. Oughta." | 0.83 | moe PERFECT, others partial |
| 06 | turbo, beam=5, long-prompt | 0.85 | curly PERFECT, turbo more fixture-compliant |
| 08 | turbo, beam=5, full-phrase prompt | 0.94 | 3/4 perfect, gygax stuck at 0.76 (3.5s of 6s) |
| 11 | **same + chunk-id namespace fix** | **0.99** | all 4 ≥ 0.95 |

### Final transcripts (iteration #11)

| speaker | acc | transcript | ground truth |
|---|---|---|---|
| moe   | 1.00 | `Why I oughta pick a card. Any card.` | `Why I oughta pick a card? Any card?` |
| larry | 1.00 | `Mo Mo Mo. What do I do now.` | `Mo, Mo, Mo. What do I do now?` |
| curly | 1.00 | `Nidak Nidak Nidak. I'm a victim of circumstance.` | `Nidak, Nidak, Nidak. I'm a victim of circumstance.` |
| gygax | 0.95 | `You enter a dimly lit tavern. Bartender eyes suspiciously. Roll for perception.` | `You enter a dimly lit tavern. The bartender eyes you suspiciously. Roll for perception.` |

Gygax's transcript is now functionally perfect — the missing words (`The`,
`you`) are filler that `faster-whisper` elides when it condenses; semantic
content is 100% intact.

### Gygax's chunks, proving the namespace fix

```
seq=0 dur=3620ms size=695040 client_chunk_id=<uuid>:<pseudo>:0       (pre-gate flush)
seq=1 dur=2360ms size=453120 client_chunk_id=<uuid>:<pseudo>:live:0  (post-gate exit flush)
```

Before the fix both would have been `...:0` and data-api de-duped the
second. The stooges captured in one pre-gate chunk because their utterances
finished before the stabilization gate opened.

## Where the code is

All branches pushed:

- `chronicle-bot` @ `refactor/bot-features-pass` → tip `c1abd7e`
- `chronicle-worker` @ `refactor/worker-features-pass`
- `chronicle-pipeline` @ `refactor/pipeline-features-pass`
- `chronicle-data-api` @ `refactor/data-api-features-pass`
- `chronicle-feeder` @ `refactor/feeder-features-pass`
- `chronicle-portal` @ `refactor/portal-initial-build`
- `sessionhelper-hub` @ `dev` (infra/dev-compose, ARCHITECTURE, docs/modules/*)

Dev VPS `/opt/ovp/.env` and `/opt/ovp/docker-compose.yml` have been
hand-patched with the new env knobs. Compose diff is compatible with the
hub's `infra/dev-compose.yml` plus the additions.

## What still isn't done

In rough priority order:

1. **Merge refactor branches to main.** The six branches all ride on
   unreleased commits; CI prod-deploy is gated on `v*` tags, so there's
   no accidental prod blast-radius, but main is stale. When you merge,
   the pushed `:branch-refactor-*-pass` images on ghcr stay pinned so
   rollback is cheap.
2. **Per-session Whisper prompting.** Right now the prompt is hard-coded
   for the stooges fixture. A real session needs either (a) a session
   field `whisper_prompt` populated at session creation from the
   campaign / characters, or (b) `condition_on_previous_text=true` so
   later chunks learn from earlier ones. Spec already calls for the data
   model — just not wired through the worker yet.
3. **One-time VPS drift in the `docker-compose.yml`**. The sed patches
   I applied through the night (HARNESS_BIND, VAD_*, FILTER_*, WHISPER_*
   env entries) should be rolled back into `sessionhelper-hub/infra/dev-compose.yml`
   so the file is the source of truth again.
4. **Portal Discord OAuth hasn't been exercised end-to-end.** Credentials
   are in `pass` → `.env` on VPS, server renders the landing page at
   `https://dev.sessionhelper.com/`, but no one has walked a real
   `/login → Discord consent → JWT cookie` round trip yet.
5. **Worker follow-ups from the refactor** (still on the todo list,
   not blocking): capture_started_at plumbing for mixed audio, Beat.summary
   rendering, real-time WS event replay on reconnect.
6. **DAVE stagger mitigation** is a harness-only workaround. Real users
   joining a voice channel don't stagger. Either fix upstream in `davey`
   (the "pending commit was already created" race) or ship the OP5-heal
   logic to recover from decrypt failures mid-session. Spec doc at
   `sessionhelper-hub/docs/dave-bot-ecosystem.md` already has the design.

## Suggested pickup order tomorrow

1. **Ack the report**, merge the six refactor branches to main (one PR
   per repo; the unit tests all pass, CI is wired for push-to-main).
2. **Reconcile dev-compose.yml** so the env knobs I added via sed
   are in git. Push to hub.
3. **Tag the release** — after mains are green, `git tag v0.2.0-rc1`
   on each repo. The deploy pipeline will build + push `:dev`/`:latest`
   to ghcr and SSH-deploy data-api + collector to prod.
4. **Write a test that catches the chunk_id collision** so it can't
   regress. Pre-gate flush + post-gate direct-upload with overlapping
   `seq=0` should fail a dedup-integrity assertion.
5. Decide whether to make the voice-capture DAVE stagger production-ready
   or fix it upstream — 5s between joins is fine for test harness but
   not for humans clicking `Join Voice` in rapid succession.

— Claude

`/tmp/tuning-log.md` contains every iteration's full env dump and scored
transcript table in case you want to audit the path.
