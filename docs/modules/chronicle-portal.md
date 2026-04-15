# chronicle-portal

Public-facing Next.js web app. Three role-based surfaces (GM, Player, Admin) over the same codebase, plus a BFF layer that enforces authorization and filters responses before they reach the browser. **The only component that faces the internet.** Where implicit trust stops and user-authored requests are validated.

Status: **Features locked. Interfaces and Behavior pending.** Implementation at `/home/alex/sessionhelper/chronicle-portal/` (greenfield — most of this is to be built).

---

## Features

1. **Three role-based surfaces on one codebase.**
    - **Admin:** full visibility across sessions, quality-score, annotate ground truth, mark segments as dataset candidates, trigger pipeline reruns, grant/revoke admin on other users.
    - **GM (per session):** session initiator. Reviews sessions they ran.
    - **Player (per session):** session participant. Reviews their own data, edits own transcripts, toggles license flags, requests deletion.
    - **Public:** anything without a logged-in identity — landing page only.

    Role derivation: admin is a `users.is_admin` flag stored in data-api. GM/Player are per-session, derived from `participants.session_id` + `sessions.initiator_pseudo_id`. A user can be admin AND a GM for one session AND a Player in another — no conflict; permissions union.

2. **Admin grant + bootstrap.** Admins grant admin to other users via a portal UI action (BFF → data-api PATCH). First-admin bootstrap is a backchannel: internal data-api endpoint `POST /internal/admin/grant { pseudo_id }` authenticated with the shared secret, callable via curl on the VPS by anyone with `pass` access. Single command to bless the first admin on day one. Post-bootstrap, admin management happens through the UI.

3. **BFF is the security boundary.** No browser ever talks to `chronicle-data-api` directly. Next.js API routes are the only thing with the shared secret; they translate session-cookie-authenticated user requests into data-api calls, enforcing role-based authorization on every endpoint. The BFF is allowed to filter, redact, or refuse fields before returning data to the client. Rule: the data-api implicitly trusts every caller with the shared secret. The BFF strips implicit trust before any user-authored request reaches that authoritative layer.

4. **Discord OAuth login.** The only user-facing auth mechanism. Implemented via Auth.js (next-auth@5). After OAuth, the portal knows the user's Discord user_id (→ derived `pseudo_id`), display name, and guild memberships. Role is derived from that identity against session/participant tables in the data-api. Sessions are JWT-based (stateless; no server-side session store).

5. **Session detail + playback.** Per-session page with:
    - Combined audio player (mixed stream).
    - Per-speaker transcript, timecoded, click-to-seek.
    - Per-speaker track playback option.
    - Segment **text** editing in-line (writes via BFF → data-api PATCH). Splits, merges, timecode edits, OOC re-classification are post-MVP; data model supports them (segments have independent `start_ms`/`end_ms`; immutable `original` preserves initial version for audit).
    - Beat + scene markers on the timeline.
    - Mute-range visualization (admin-only edit UI).

6. **Consent + license management.** Players can review and toggle their own consent scope and license flags (`no_llm_training`, `no_public_release`) after the fact. Changes propagate via BFF → data-api → downstream release-time gating.

7. **Player self-deletion.** Players can request permanent deletion of their audio from any session they participated in. Portal issues the data-api deletion call (via BFF); cascades chunks + pipeline outputs. Irreversible. Confirmation dialog + audit trail.

8. **Admin surfaces.** Admin-only views:
    - Quality-score sessions (1–5 + notes).
    - Annotate ground truth against pipeline output (corrections for pipeline validation).
    - Mark segments as dataset candidates (feature flag for future release).
    - View audit log for a session.
    - Trigger pipeline reruns (via worker admin endpoint).
    - Grant / revoke admin on other users.

9. **Minimal live-monitoring indicator.** Session list + detail pages show a `🔴 recording` badge when the session is active. Driven by BFF subscribing to data-api WS `session_state_changed` events and pushing updates to the browser via Server-Sent Events. No live transcript streaming in MVP — that's Phase 2+. The "is it recording?" signal exists from day one.

10. **Observability.** Next.js server-side tracing, BFF request latency + error metrics, per-route analytics for feature usage.

---

## Interfaces

Two surfaces: browser-facing pages + browser-facing BFF API. The portal is one Next.js app serving both.

### Browser-facing pages

- `/` — landing, public
- `/login` — Discord OAuth entry
- `/logout`
- `/dashboard` — signed-in home; role-specific
- `/sessions` — session list (filtered by role)
- `/sessions/[id]` — session detail + playback. Admin affordances (quality score, annotate, audit log, mute editing) render inline, gated on `is_admin`
- `/me` — user profile: consent, license, deletion requests, alias history
- `/admin` — admin-only ops: user list, grant admin, etc.
- `/api/auth/*` — Auth.js mounts

### BFF HTTP API (`/api/*`)

All routes require session-cookie auth. The BFF resolves the caller's `pseudo_id` + `is_admin` before dispatch. No per-request caching — lookup is cheap, caching is premature.

Sessions:

- `GET /api/sessions` — list visible to the caller (admin: all; otherwise participated-in or initiated)
- `GET /api/sessions/:id` — detail (403 if not participant / GM / admin)
- `GET /api/sessions/:id/summary` — aggregate stats
- `POST /api/sessions/:id/rerun` — admin only; proxies to worker admin endpoint

Audio:

- `GET /api/sessions/:id/audio/:pseudo_id/stream` — streams Opus-in-OGG (no transcoding; bandwidth-friendly). Supports HTTP Range for seek. 403 on access violation
- `GET /api/sessions/:id/audio/:pseudo_id/chunks` — chunk metadata list for scrubbing

Transcripts:

- `GET /api/sessions/:id/segments` — returns segments visible to caller; filters to own `pseudo_id` for players; GM/admin get all
- `PATCH /api/segments/:id` — text edit; only owning player (or admin) can edit
- `GET /api/sessions/:id/beats` / `/scenes`
- `PATCH /api/beats/:id` / `/scenes/:id` — admin only

Consent / license / deletion:

- `PATCH /api/me/sessions/:id/consent`
- `PATCH /api/me/sessions/:id/license`
- `POST /api/me/sessions/:id/delete-my-audio` — hard-delete own data in that session

Mute ranges (admin):

- `GET|POST|DELETE /api/sessions/:id/participants/:pid/mute[/:range_id]`

Admin management:

- `GET /api/admin/users` — list, filterable
- `PATCH /api/admin/users/:pseudo_id` — set `is_admin`
- `GET /api/admin/audit?session_id=&limit=`

Live events (SSE):

- `GET /api/sessions/:id/events?types=session_state_changed,chunk_uploaded,segment_created,...` — generic event-subscribe endpoint, `text/event-stream` response. Takes an `events` filter list. Future-proof: when live transcripts arrive, same endpoint streams `segment_created` and consumers add the type to their subscription.

### Outbound — data-api HTTP

Exactly the interfaces in `chronicle-data-api.md`, called with shared-secret auth. One long-lived `DataApiClient` per portal process; re-auth on restart + on 401.

### Outbound — worker admin HTTP

- `POST http://worker:8020/admin/rerun/{session_id}` — invoked by `POST /api/sessions/:id/rerun` admin endpoint

### Outbound — data-api WebSocket

One WS subscription per portal process to the data-api bus. The portal multiplexes events onto per-user SSE connections, filtering by the user's session access + their SSE `?events=` request.

### Environment variables

| Var | Required | Default | Meaning |
|---|---|---|---|
| `DATA_API_URL` | yes | — | e.g. `http://data-api:8001` |
| `SHARED_SECRET` | yes | — | Data-api service auth |
| `WORKER_ADMIN_URL` | no | `http://worker:8020` | Worker admin base |
| `NEXTAUTH_URL` | yes | — | Public URL (e.g. `https://app.sessionhelper.com`) |
| `NEXTAUTH_SECRET` | yes | — | JWT signing key |
| `DISCORD_CLIENT_ID` | yes | — | Discord OAuth app id |
| `DISCORD_CLIENT_SECRET` | yes | — | Discord OAuth secret |
| `BIND_ADDR` | no | `0.0.0.0:3000` | Next.js listen (behind Caddy) |
| `NODE_ENV` | no | `production` | Next.js mode |

### Observability

- Next.js access logs
- OpenTelemetry SDK emitting tracing compatible with Rust services
- Metrics via `prom-client`:
  - `portal_request_latency_ms{route}` — histogram
  - `portal_bff_upstream_latency_ms{upstream}` — histogram
  - `portal_bff_errors_total{upstream,status}` — counter
  - `portal_sse_subscribers` — gauge
  - `portal_oauth_attempts_total{result}` — counter

---

## Behavior

### Invariants (always hold)

1. **No browser-to-data-api calls.** Ever. The BFF is the only component in the system holding `SHARED_SECRET`. Browsers carry a signed session cookie (Auth.js JWT); that cookie authorizes BFF access, and the BFF authorizes data-api access.
2. **Every BFF endpoint enforces authorization per-user, per-resource.** There is no route that says "trust whoever's logged in." Every handler asks "is this caller allowed to read/mutate THIS specific session/segment/participant?" and resolves from data-api state.
3. **Admin privileges are runtime-evaluated.** `is_admin` is re-read on every request (from the users table or a short-TTL cached lookup; not baked into the JWT beyond user identity). Revoking admin takes effect on next request.
4. **User-authored PATCH bodies are validated at BFF.** The data-api trusts its callers; the BFF does not. Any client-supplied `author_service`, `author_user_pseudo_id`, state transitions, or other privileged fields are stripped at the BFF and re-set by the BFF from the authenticated session.
5. **Deletions are audit-logged.** Every `delete-my-audio`, `PATCH consent → decline`, mute edit, admin grant/revoke fires an audit-log row via data-api. Tombstones retained even after content wipes.
6. **SSE connections are session-scoped and closed on signout.** No cross-user event bleed; subscriptions are filtered by the authenticated user's visible sessions.

### Auth lifecycle

```
browser : visits /login
browser : redirected to Discord OAuth
discord : returns to /api/auth/callback/discord with authorization code
next.js : exchanges code for Discord access token; fetches user profile (id, name, guilds)
next.js : computes pseudo_id = sha256(discord_user_id)[0:24]
next.js : upserts user row via data-api POST /internal/users
next.js : POST /internal/users/{pseudo_id}/display_names (record alias)
next.js : issues signed JWT { pseudo_id, display_name, exp } as cookie
browser : subsequent requests carry the cookie
```

On every BFF request, Auth.js middleware decodes the JWT → sets request.user = `{ pseudo_id, display_name }`. BFF handler then queries data-api for `is_admin` + role-per-session as needed.

JWT TTL: 7 days. Refresh on activity. On Discord revoke / data-api user deletion, next request's user lookup fails → logout.

### Authorization decisions (the BFF's job, not the data-api's)

Per-endpoint authorization table (abbreviated):

| BFF endpoint | Caller must be… |
|---|---|
| `GET /api/sessions` | signed in (response scoped: admin=all; else participant+initiator) |
| `GET /api/sessions/:id` | admin OR participant-in-this-session OR initiator |
| `GET /api/sessions/:id/audio/*` | same as above |
| `PATCH /api/segments/:id` | admin OR owning player (segment.pseudo_id == user.pseudo_id) |
| `PATCH /api/me/sessions/:id/consent` | participant-in-this-session |
| `POST /api/me/sessions/:id/delete-my-audio` | participant-in-this-session |
| `POST /api/sessions/:id/rerun` | admin |
| `PATCH /api/admin/users/:pseudo_id` | admin |

Failed auth = 403 with `{ error: "forbidden" }`. No leaking of "does this resource exist but you can't see it" — 404 for both non-existent and forbidden unless the caller could otherwise infer existence.

### Response filtering

Even when authorized, responses are filtered:

- `GET /api/sessions/:id/segments` — players see only their own segments + public metadata; admin/GM see all
- `GET /api/sessions/:id/summary` — players see aggregate counts scoped to their own audio; admin sees everything
- Audit-log fields (`author_service`, `author_user_pseudo_id`) stripped from client responses unless caller is admin

### SSE / live updates

BFF holds one WebSocket subscription to data-api. Incoming events fan out to per-connection SSE streams, filtered by:

1. The user's visible sessions (computed at SSE connect time from their role)
2. The client's `?events=` request (subset of event types they care about)

SSE disconnect: browser closes → BFF closes the per-connection stream. When the data-api WS disconnects (reconnecting), BFF closes all SSE streams with a `retry` directive; browsers reconnect via EventSource's built-in retry.

### Error handling

- **Data-api unreachable:** BFF returns 502 to the browser. Logs the upstream error. Does not retry in-line — the browser will retry if the user reloads.
- **Auth.js session invalid:** 401; browser redirects to `/login`.
- **Auth.js JWT expired:** 401; browser redirects.
- **Discord OAuth failure:** lands on `/login?error=...` with a user-safe message.
- **BFF panic:** caught by Next.js error boundary, returns 500 with minimal client-facing info, full stack in server logs.

### Scope fence

The portal does **not**:

- Host or proxy the data-api URL to clients. Data-api is invisible to browsers.
- Touch Postgres, S3, Whisper, or songbird directly. All backend access is via data-api (+ worker admin for reruns).
- Manage Discord bot logic — joining voice, recording, playing audio. Bot's job.
- Run any pipeline or transcription compute. Worker / pipeline's job.
- Grant itself admin status — bootstrap is outside the portal (shared-secret data-api call).
- Do real-time audio streaming (live listen-in). Phase 2+; architecture allows via SSE/WS extension but not built yet.
- Authenticate non-Discord users. Discord OAuth is the only ID provider.

Additions require explicit Features entry with Interfaces + Behavior implications.
