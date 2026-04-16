# Overnight report — 2026-04-16

Portal PR arc landed (4/4 merged to main, shipped to dev), seven backend
contract bugs fixed by an audit-driven schema sweep, disk-full PANIC
recovered and a nightly prune shipped to prevent recurrence, data-api
gained `/internal/admin/users` + PATCH admin flag endpoints, worker
admin HTTP is now reachable from the portal bridge, and the full admin
smoke loop (admin list → rerun → mute CRUD → license toggle) is green
end-to-end on dev.

---

## Landed tonight

### Portal PR arc — 4/4 on main, shipped to dev

Commits `a265954` → `44299d2`:

1. **PR 1/4 — design foundation + test infra.** Crimson Pro + Inter via
   `next/font/google`, unified 4px radius via `--radius` CSS var,
   Vitest + RTL + happy-dom wired up (`npm run test`).
2. **PR 2/4 — admin rerun + mute-range CRUD.** `RerunButton` POSTs to
   `/api/sessions/:id/rerun`, `MuteRanges` component with full per-participant
   CRUD. Server-side auth via `resolveSessionRole`.
3. **PR 3/4 — downloads bar.** Transcript JSON/text + per-speaker /
   mixed audio download buttons. Uses signed BFF streams.
4. **PR 4/4 — GM session manage page.** `/sessions/:id/manage` with
   summary cards (participants, duration, chunks) + roster. Manage
   button appears on session detail for GM + admin via `resolveSessionRole`.

Dev deploy path for all four: merge → `:branch-main` ghcr tag →
`docker compose up -d --force-recreate portal` on the VPS.

### Schema audit — seven contract bugs fixed

Commits `a503ab2` → `b30bdc9`. Smoke kept surfacing ZodError crashes;
pivoted from whack-a-mole to an audit sub-agent that diffed every
data-api response against every Zod parser in the portal. Fixes:

- **Dashboard + sessions list no longer crash on null counts.**
  `participant_count`, `segment_count`, `duration_ms`, `chunk_count`
  all `.nullable().default(0)`.
- **`guild_id` is a number, not a string.**
  `z.union([z.string(), z.number()]).transform(String)` so UIs keep
  treating it as text.
- **`getUser` envelope.** GET `/internal/users/:id` returns
  `{user, latest_display_name}`, POST returns flat user — handled in
  client.
- **Participant `pseudo_id` vs `user_pseudo_id`.** Schema transform
  normalizes so downstream always reads `user_pseudo_id`.
- **Session dates + flags.** Added `abandoned_at`, `deleted_at`,
  `mid_session_join`, `data_wiped_at`, `client_id`, segment `title`,
  `summary`, `flags`, `etag`.
- **Graceful auth failure.** Dashboard + related server components
  catch `AuthError` and redirect to `/login` instead of crashing.
- **CI npm ci flakiness.** `--legacy-peer-deps` in Dockerfile for
  React 19 vs RTL 16 peer conflict.

### data-api: admin endpoints (v0.2.1)

Sub-agent added:
- `GET /internal/admin/users` — list all users (for `/admin` page).
- `PATCH /internal/users/:pseudo_id { is_admin }` — toggle admin flag
  from the UI.

Tag `v0.2.1` pushed → auto-deployed to dev. **Gotcha worth flagging in
the morning:** the deploy workflow also pushes `v*` tags to prod, so
prod picked this up too. No data-visible change (additive routes only)
but the v-tag workflow behaviour needs a sanity pass — see
`ops-followups.md #68`.

### Disk recovery + nightly prune

`postgres` PANIC'd around 23:30 local with `No space left on device`
(root at 100%). `docker image prune -a -f` reclaimed 5.5GB, postgres
recovered cleanly. Shipped `sessionhelper-hub/scripts/nightly-prune.sh`
(cron at 03:15 UTC, 15 min after nightly-soak):

```
docker image prune   -a -f --filter "until=48h"
docker builder prune -a -f --filter "until=168h"
```

Logs to `/var/log/chronicle-prune/prune-<stamp>.log`, rotated at 14
days. Deliberately avoids `docker system prune` (too aggressive).
Entry added to `ops-followups.md`. Current disk: 23% used post-prune
(vs 86% pre-cleanup).

### Worker admin HTTP — reachable from portal bridge

Portal runs on the `ovp` bridge; worker uses `network_mode: host` so
Docker DNS can't find it. Fixed by:
- `extra_hosts: ["host.docker.internal:host-gateway"]` on portal so it
  can reach the host gateway.
- `WORKER_ADMIN_ENABLED=true` + `ADMIN_BIND_ADDR=0.0.0.0:8020` on
  worker (default was 127.0.0.1 which isn't reachable from the
  docker bridge IP).

Verified: rerun button → portal → worker admin HTTP → worker claims the
session and enters the one-shot runner. Worker log:
`admin HTTP listening bind=0.0.0.0:8020`, then `one-shot: entering
run session=...`.

### Admin fix: /me routes for admin users

`resolveSessionRole` short-circuited admin with `participantId=null`,
which meant admin users couldn't toggle their own consent / license /
delete-my-audio on the Me page (403 forbidden). Commit `5e6c4da`:
admin still gets `role=admin` for elevated ops, but now also gets
their own `participantId` populated if they're a participant in the
session. /me routes unblocked.

---

## Smoke matrix — green on dev

| Flow | Status |
|---|---|
| Login (Discord OAuth dev app) | ✅ |
| /dashboard (no crash on null counts) | ✅ |
| /sessions list | ✅ (React hydration warning — see followups) |
| /sessions/:id detail | ✅ |
| /sessions/:id/manage (GM + admin) | ✅ |
| /admin (lists 9 users) | ✅ after v0.2.1 |
| Rerun button → worker | ✅ (202 → worker claims) |
| Mute range add → list → delete | ✅ (POST 201 → DELETE 204) |
| License toggle (admin's own) | ✅ after `5e6c4da` |
| Consent dropdown change (full → decline → full) | ✅ |
| Sign out | ✅ (redirects to `/`, public home) |
| Segment text edit | ⏸ blocked: no transcribed segments on dev |

Portal `v0.3.1` tagged and pushed. Follow-up `v0.3.2` landed with
hydration-warning fix + admin "(no name)" cleanup (see below).

### Late-night follow-ups (post-initial-report)

- **Hydration warning #418 fixed.** `src/components/local-date.tsx` is
  a client component that wraps dates in `<time
  dateTime={iso} suppressHydrationWarning>` and re-renders with the
  user's local timezone after mount. Migrated all four pages
  (dashboard, sessions list, session detail, manage, me). Also
  coerces null participant/segment counts to 0 on the sessions list.
- **Admin row cleanup.** Dropped the "(no name)" placeholder — row
  shows just the pseudo_id when no display name exists. Underlying
  cause (display names never recorded) still open; flagged below.
- **Test fixture.** `filters.test.ts` mkSegment now includes
  `start_ms`/`end_ms` to satisfy the tightened `SegmentSchema`.
  Typecheck now clean across src + tests.
- Portal `v0.3.2` tagged and pushed.

---

## Late-morning: transcript viewer restored + clean demo data (`v0.4.0`)

You flagged before heading to work that the rich transcript interface
was gone. Confirmed — the BFF refactor (`6f1843b`, 2026-04-12)
dropped the 10e3bd0 viewer; tonight's PRs were built on the resulting
132-line skeleton without realizing what was missing.

**Restored as `chronicle-portal v0.4.0`:**

- `src/components/transcript-viewer.tsx` (~470 lines) — per-speaker
  color blocks, GM auto-detect, block grouping, **side-by-side
  OverlapBlock for concurrent speakers**, click-to-seek (segment dots
  and timestamps), double-click inline edit. Adapted from 10e3bd0 to
  current schema (`start_ms`/`end_ms`, `pseudo_id`) and BFF auth.
- `src/lib/audio-assembler.ts` — assembles raw PCM chunks from data-api
  into a playable WAV server-side. The data-api never had a
  `/audio/.../stream` endpoint; this is why audio was broken on
  every session. Mixed stream falls back to the first speaker if no
  mixed track exists.
- Participant enrichment: `fetchSessionDetail` now stitches
  `latest_display_name` per pseudo_id (session_participants table
  doesn't carry it).
- `GET /api/sessions/:id/participants` route (only `[pid]` subroute
  existed before).

**Demo data on dev:**

Cleared 37 cruft sessions / 78 segments via TRUNCATE (kept 9 users
so OAuth still works). Injected the chaotic-tavern scenario via
`chronicle-feeder/scripts/inject-session.py` (patched to refresh the
auth token on 401 mid-upload):

- Session `ac0fdae6-e913-4ff5-9f8c-9667a511db85` "Crimson Tankard Demo"
- 4 participants: gygax_gm (GM), moe_torvin, larry_sera, curly_pip
- ~20 min real synthetic audio in S3 (per-speaker WAV)
- 267 segments seeded from ground-truth.json (10 beats, 4 scenes,
  57 of which are concurrent-speaker overlaps)
- Status forced to `transcribed` via SQL (worker can't transcribe;
  separate Whisper-tunnel issue)

**Smoke verified live on dev:**

- Speaker-labeled color blocks render
- Audio player shows 20:18 duration (assembler working)
- "↔ CONCURRENT" overlap blocks render side-by-side as expected
- No console errors

**Deferred from the original viewer (still on the list):**

- SSE live updates as new segments stream in
- Multi-layer correction history (each edit becomes an undo-able layer)
- Scene/beat navigation sidebar
- Auto-scroll on active block during playback

These are kept as TODOs so the next pass can add them on top of the
restored shell.

## ⚠️ Flagged by user — revised transcript interface lost in BFF refactor

Not a tonight regression, but surfaced tonight: the prior client-side
transcript viewer (last touched at `10e3bd0` on 2026-04-10) was
dropped during the `6f1843b feat(portal): initial BFF build (#2)`
refactor. Tonight's PRs were built on top of the post-refactor 132-line
skeleton — they did not bring the viewer back.

What was in the previous viewer (recoverable from git at `10e3bd0`):

- `src/app/sessions/[id]/page.tsx` (~990 lines): overlap-column
  layout for concurrent speakers, click-to-seek playback, scene
  markers, confidence visualization, excluded-segment handling,
  multi-layer correction history per segment.
- `src/components/transcript/`: `flagged-segment`,
  `playback-controls`, `segment-editor`, `segment-row`,
  `transcript-list`.
- `src/hooks/`: `use-audio-playback`, `use-session-events`,
  `use-transcript`.
- `src/app/api/sessions/[id]/`: `beats/route.ts`, `scenes/route.ts`.

Restore path: `git checkout 10e3bd0 -- <paths>`, then port direct
data-api calls to the BFF (`dataApiClient.*` + `page-data` fetchers).
Worth doing carefully — this is real UX work, not throwaway.

## Flagged for morning

1. **v0.2.1 data-api on prod.** Tag-push workflow deployed it. Additive
   only; no schema migrations. Still — confirm the prod deploy is
   intentional and consider narrowing the prod auto-deploy predicate
   to `v*-rc*` or explicit prod-only tags. `ops-followups.md #68`.

2. **React hydration warning #418 on `/sessions`.** Minified error, but
   the pattern points at server vs client date formatting drift
   (`formatDate` uses `toLocaleString` — timezone difference between
   Node and browser). Not blocking; worth a cleanup pass to freeze the
   format on the server and render the ISO string on both sides.

3. **Chrome "Dangerous site" flag on dev.sessionhelper.com.** Spawned
   an investigation in a fresh thread — Google Safe Browsing picked up
   the OAuth redirect loop during the config churn. Expected to clear
   24–72h after clean login traffic returns.

4. **No transcribed segments on recent dev sessions.** Status shows
   `transcribed` but `segment_count=0` on every recent session. Likely
   Whisper tunnel or VAD threshold; not a portal problem. Worth a
   pipeline-side look.

5. **"(no name)" on /admin user list.** Users page shows IDs but no
   display names — `latest_display_name` never populated. Need the
   bot to call `recordDisplayName` on session join (or backfill).

---

## Still open on the plan

- Segment text edit smoke (blocked on segments existing — pipeline-side).
- Morning review of flagged items (see above).

---

## Health checks run tonight

- Disk: 86% → 23% after `docker builder prune -a -f` (21GB cache).
- Postgres: healthy after recovery.
- All 9 dev services up: `postgres`, `data-api`, `worker`, `portal`,
  `collector`, `feeder-{moe,larry,curly,gygax}`.
- Worker admin listening on `0.0.0.0:8020`.
- Portal routable at `https://dev.sessionhelper.com` behind Caddy TLS.
