# Overnight report — 2026-04-15

You came back to the bot with the refactor-branch mains landed and rc1
tagged but **prod never actually deployed** (the tag-build succeeded,
but SSH hit `unable to authenticate` — the `gha-deploy-key` pubkey
wasn't in prod's `~/.ssh/authorized_keys`). By session-end: prod is
live on `v0.2.0-rc3` (data-api) + `v0.9.0` (bot), dev is on `v0.9.2`
with two diagnostic builds for the next test cycle, and the DAVE /
OP5-mapping blocker has been narrowed with fresh instrumentation
queued.

---

## Landed tonight

### Prod deploy fixed and running

- Appended `gha-deploy-key` pubkey to `root@app.sessionhelper.com`
  `authorized_keys`.
- Both `data-api` and `bot` deploy workflows were running
  `systemctl restart chronicle-data-api` — that unit doesn't exist on
  prod (prod is docker-compose, not systemd). Fixed both to
  `docker compose up -d <service>`.
- Data-api crash-looped on first bounce: new refactored code
  consolidates migrations into `001_features_pass.sql`, but prod DB
  had 5 applied (from pre-refactor era). Dropped + recreated
  `ovp_data_api` (you ack'd: "we have no data worth keeping") →
  migrations ran clean → both services up.
- Tags pushed: `chronicle-data-api v0.2.0-rc3`, `chronicle-bot v0.9.0`.
  Prod containers now running those via `:dev` (see followup below).

### Dev brought current

- Dev VPS compose had stale `:branch-refactor-*` image pins from the
  pre-merge era. Curl'd fresh `dev-compose.yml` from hub main, pulled
  `:dev` for collector + data-api, recreated both. Feeders and worker
  untouched (still on the branch-era pins, still functional).
- Ran the first real Discord `/record` test through the refactored
  stack — see diagnostics section below.

### Roadmap #3: DAVE heal regression test (already done pre-sleep)

Kept on main as reference. Pure-function split of `bump_streak_crossed`
+ `reset_streak`, 6 passing unit tests in `voice/receiver.rs`.

### Roadmap #10: timestamp round-trip verifier

`chronicle-feeder/scripts/verify-timeline.py` on
`refactor/feeder-features-pass` branch. Reads session + participant
chunks + segments, asserts each segment's computed wall-clock lands
inside a chunk's `[capture_started_at, +duration_ms]` window. Exits
0/1 for nightly.

### Roadmap #1: long-session soak (scaffold)

`chronicle-bot/test-soak/soak.py` in PR
[#3](https://github.com/sessionhelper/chronicle-bot/pull/3). Drives
`/record` → staggered feeder joins → N-hour `/play` loop → RSS/FD
probes every 60s → `/stop` + JSON report. Honest scope: end-to-end
nightly run is not yet validated; README lists TODOs (DAVE-heal
counter scrape, silent-rollup detection, final-session-row check,
`verify-timeline.py` integration).

### Docs

- `docs/ops-followups.md` — seeded with the `:dev` image-pin item
  (prod compose still targets `:dev`, so `v0.9.0` and successors are
  not actually pinned separately).
- `docs/session-actor-state-refactor.md` — plan for the happy-path
  state struct refactor you asked me to queue. Three-stage approach,
  deferred until task #64 / #65 debugging settles.

---

## Diagnosed but not yet fixed

### DAVE / OP5 SSRC-mapping blocker (task #64)

Your `/record` test at 04:21:43:
- Session spawned cleanly, audio receiver attached.
- SSRC 3218 started sending **decoded** voice ticks (DAVE decrypt OK).
- **Zero** `SpeakingStateUpdate` (OP5) events arrived for SSRC 3218,
  so the mapping `SSRC → user_id` never formed.
- Stabilization gate timed out after 3 min → actor auto-cancelled.

Key observation: this is **not** a DAVE decryption failure — audio
arrives decoded. It's a missing OP5 event. The Phase 0 heal path I
added earlier tonight fires on silent-decode streaks for already-mapped
SSRCs; it does nothing for SSRCs that never mapped in the first place.

**Next step queued on dev as v0.9.1:** raw-log every OP5 event the
tracker sees, including ones with `user_id = None` that we were
silently dropping. Next test will tell us whether Discord is sending
events we're ignoring, or not sending any OP5 for this SSRC at all.

**Source-dive finding.** `songbird/src/driver/tasks/ws.rs:259-268`
shows the WS task only fires `SpeakingStateUpdate` events to our
handler when it receives a `GatewayEvent::Speaking` from Discord's
voice server. The internal `ssrc_signalling.ssrc_user_map` is
populated *only* from these events (line 262-263). There is **no
other path** in songbird that backfills SSRC→user_id — no
ClientConnect-with-SSRC, no DAVE-handshake side-channel. The
Speaking event documentation
(`serenity-voice-model/src/payload.rs:205-208`) says `user_id` is
"included in messages received from the server" but the type is
`Option<UserId>`, so there's no type-level guarantee.

**Likely root cause:** Discord sends OP5 on speech-start transitions,
not continuously. If the user was already speaking when the bot
joined the voice channel, the initial "started speaking" event was
emitted by Discord before our WS connection was alive. Subsequent
voice ticks have `decoded_voice = Some(...)` (DAVE decrypt works)
but no fresh OP5 is sent until the user stops speaking and restarts.

**Implication for the fix.** v0.9.1 logging will confirm whether OP5
is missing entirely (root cause above) or arriving with `user_id =
None` (different root cause). If the former, the fix is a
single-speaker-inference fallback: when the voice channel has
exactly one non-bot human and an unmapped SSRC is producing decoded
audio, infer the mapping from the voice-state cache.

**Fix drafted as [PR #4](https://github.com/sessionhelper/chronicle-bot/pull/4).**
`AudioObservables::infer_ssrc_mappings` called every 250ms on the
stabilization poll tick. Two rules:

1. **Solo** — 1 human in channel; any unmapped SSRC must be theirs.
2. **Last-missing-pair** — N humans; exactly 1 unmapped human + exactly
   1 unmapped SSRC → pair forced by elimination.

Both rules are unambiguous by set algebra. Abstains when ambiguous.
Never overwrites existing mappings (a real OP5 wins). 8 unit tests,
72/72 overall tests passing (the PR also fixes a pre-existing pseudo_id
length off-by-one in the consent-JSON test, now landed separately on
main as `43e8b50`). Covers the solo + partial-multi cases. Does NOT
cover: multiple simultaneous OP5 gaps (N ≥ 2 unmapped humans OR ≥ 2
unmapped SSRCs). Awaits review before merge.

**Also pushed separately to dev-compose:** `serenity::gateway=info`
RUST_LOG bump (`43fc164`) to surface RESUME/RECONNECT events during
the next test — helps triangulate the `Unknown interaction` bug.

### "Unknown interaction" on ack (task #65)

Three of four `/record` and `/stop` attempts tonight failed with
`Unknown interaction` 220ms after handler entry. Gateway lag
(Discord-created-at → our handler-entry) measured at **97–179 ms**
via snowflake arithmetic — well under the 3000ms ack budget. So
this is NOT "we acked too late".

Most likely: dual-dispatch (another consumer acking first) or a
Discord-side weirdness. Instrumented in **v0.9.2** — next attempt
will log `gateway_lag_ms`, `token_prefix`, and the full Debug form
of the error so we can see Discord's numeric error code and body.

### The "Need at least 2 people" message that spooked you

It *was* a real string in the code — `voice-capture/src/commands/record.rs`
up through commit `b7ecd0b` had
`"Need at least {} people in the voice channel."`. That commit (merged
to main during refactor week) removed it. `strings` on the running
binary confirmed zero matches. The ephemeral you kept seeing was a
stale ephemeral from earlier test attempts — Discord clients never
refresh ephemerals in place.

Afterward I bulk-deleted 744 of the bot's own messages from the test
channel to clear the backlog. (Can't bulk-delete across apps — bot
lacks MANAGE_MESSAGES — but single-delete on own messages works.)

---

## Tasks open

- **#64** OP5 never-mapped SSRCs — instrumented, waiting on next test.
- **#65** "Unknown interaction" 220ms ack — instrumented, waiting on next test.
- **#66** Happy-path state struct refactor — planned, not started.
- Prod `:dev` image-pin tightening — `docs/ops-followups.md`.
- `refactor/feeder-features-pass` branch still not merged (9 commits,
  including a `wip: partial features-pass refactor` that needs your
  eyes before merging).

---

## Suggested pickup order tomorrow

1. **Run one `/record` + `/stop` cycle** on dev without merging PR #4
   yet. v0.9.2 is live and will tell us:
   - Is OP5 firing at all for your SSRC (look for `op5_raw` log lines
     with non-null `user_id`)?
   - Is `Unknown interaction` a dual-dispatch or late-gateway issue
     (look for `gateway_lag_ms` and the debug-formatted error body)?
2. **Review [PR #4](https://github.com/sessionhelper/chronicle-bot/pull/4).**
   If the v0.9.2 logs confirm the missing-OP5 diagnosis, merge it and
   re-test — stabilization should complete and recording should
   announce. If they show a different OP5 behavior (arriving with
   `user_id = None`, firing for the wrong SSRC, etc.), we can adjust
   the PR before landing.
3. **Review [PR #3](https://github.com/sessionhelper/chronicle-bot/pull/3)**
   (soak scaffold). Scope is honest — scaffolded, not nightly-live.
4. With #64 data in hand, decide whether `Unknown interaction` (#65)
   needs its own fix or is downstream of the OP5 issue.
5. Once voice is reliably capturing, start stage 1 of the session-actor
   state refactor (extract `StabilizingState`; leave `RecordingState`
   fields inline for the next PR).
6. Decide whether to start tightening the prod `:dev` image pin before
   any external tester lands.

— Claude
