# Admin users surface — spec

The `/admin` users page currently renders a flat list of pseudo_ids
with an admin toggle switch next to each row. That shape is wrong:

- **The pseudo_id is an identifier, not a name.** A 24-hex string
  answers "which internal ID is this" but not "who is this person?"
  — which is what an admin actually needs to see first.
- **The only action is "flip admin on/off".** That frames the page
  as a permissions settings panel, but the real admin workflows on
  a user are investigation (why is this user in a weird state?),
  data-governance review (have they been wiped? are they consented?),
  and situational moderation (demote a compromised admin, trigger a
  user-wide wipe on request). Admin promotion is rare enough that
  it shouldn't dominate the row.
- **There's no context.** An admin can't tell whether a row
  represents someone they've met last night vs a pseudo_id from a
  zombie session in January, or whether the user has actually
  consented, or how many sessions they've been in.

This document specs what the surface should become and what the
data-api needs to support it.

---

## Workflows the surface must serve

In rough priority order:

1. **"Who is this?"** — cross-reference a pseudo_id that shows up
   elsewhere (a session participant row, a log line, a support
   ticket) against a human-recognizable name.
2. **"Are they okay?"** — check for attention-needing states: data
   wiped, no consent recorded, no display name ever captured, never
   joined a session.
3. **"What have they done here?"** — scan session count + last-active
   to understand whether this is an active contributor or a stale
   record.
4. **"Show me their history."** — open a user-detail view with the
   list of sessions they participated in, the display names they've
   been known by, and recent audit-log entries.
5. **"Promote/demote an admin."** — rare, deliberate; confirmation
   required; audit-logged.
6. **"Trigger a user-wide data wipe."** — very rare, tied to a
   deletion request; confirmation; audit-logged; downstream cascade
   into session_participants + chunks + segments is a separate
   concern (already wired via `data_wiped_at`).

Not in scope yet: invite flow, impersonation, role schemes beyond
`is_admin`, bulk ops.

## Surface shape

Master/detail, not flat list.

### Master — `/admin/users`

A table, one row per user. Columns:

| Column | Source | Notes |
|---|---|---|
| Display name | `user_display_names` latest by `last_seen_at` | Fallback to "—" when unset. Shown bold. |
| pseudo_id | `users.pseudo_id` | Mono font, muted color, secondary. Click to copy. |
| Admin | `users.is_admin` | Read-only badge here. No toggle on this row. |
| Sessions | `COUNT(DISTINCT session_id) FROM session_participants` | "0" means the user exists but never joined a session. |
| Last active | `MAX(started_at) FROM sessions JOIN session_participants` | Relative time ("3d ago"). "Never" when 0 sessions. |
| Status | derived | Badges: `wiped` if `data_wiped_at` set, `never-consented` if user has ≥1 session but no participant row has `consent_scope` set, `no-display-name` if no `user_display_names` rows. |
| — | — | Row click → `/admin/users/{pseudo_id}`. |

Default sort: `last_active DESC NULLS LAST` so active contributors
float to the top. Secondary sort by `created_at DESC`.

Filters (v1): text search that matches display name OR pseudo_id
prefix; a filter chip set for each status badge. No date-range
filter in v1 — add only if somebody asks.

The admin toggle **does not appear on the list row.** It moves
to the detail page behind a confirmation.

### Detail — `/admin/users/{pseudo_id}`

Four sections, top to bottom:

1. **Header card**: full pseudo_id (mono, copyable), most recent
   display name, `is_admin` badge, `data_wiped_at` badge if set,
   `created_at`. "Copy pseudo_id" button. A "Back to users" link.
2. **Admin controls**:
   - `is_admin` toggle behind a confirmation dialog ("Promote
     `<display_name>` (`<pseudo_id>`) to admin?" / reverse). Click →
     dialog → confirm → PATCH → audit log entry. Disabled when
     operating on self (can't unadmin yourself from the UI; use CLI).
   - `Wipe this user's data` button, destructive style, behind its
     own confirmation. Also audit-logged. Not implemented in v1 —
     render as disabled with a "coming soon" tooltip.
3. **Display-name history**: table from `user_display_names` for
   this pseudo_id, sorted by `last_seen_at DESC`. Columns: name,
   source, first seen, last seen, seen count. Useful for detecting
   impersonation patterns and for cross-referencing nicknames.
4. **Session participation**: list of sessions the user was in,
   sorted by `started_at DESC`. Columns: campaign/title, started
   at, duration, status, consent scope on that session, link to
   the session detail page.
5. **Audit log** (v1 optional): last N entries from `audit_log`
   where the actor or the subject was this pseudo_id. Skip if N+1
   cost becomes unreasonable; can land in v2.

## Data-api shape

Two new endpoints, both under `/internal/admin/users`:

### `GET /internal/admin/users` (enrich the existing route)

Today returns `Vec<User>` with just `pseudo_id`, `is_admin`,
`data_wiped_at`, `created_at`. Extend to return
`Vec<AdminUserListItem>`:

```rust
pub struct AdminUserListItem {
    pub pseudo_id: PseudoId,
    pub is_admin: bool,
    pub data_wiped_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub latest_display_name: Option<String>,
    pub session_count: i64,
    pub last_active_at: Option<DateTime<Utc>>,
    pub has_consent_on_file: bool,
}
```

Single SQL query:

```sql
SELECT
    u.pseudo_id,
    u.is_admin,
    u.data_wiped_at,
    u.created_at,
    d.display_name                         AS latest_display_name,
    COALESCE(sp.session_count, 0)          AS session_count,
    sp.last_active_at                      AS last_active_at,
    COALESCE(sp.has_consent_on_file, FALSE) AS has_consent_on_file
FROM users u
LEFT JOIN LATERAL (
    SELECT display_name
    FROM user_display_names
    WHERE pseudo_id = u.pseudo_id
    ORDER BY last_seen_at DESC
    LIMIT 1
) d ON TRUE
LEFT JOIN LATERAL (
    SELECT
        COUNT(DISTINCT session_id) AS session_count,
        MAX(joined_at) FILTER (WHERE joined_at IS NOT NULL) AS last_active_at,
        bool_or(consent_scope IS NOT NULL) AS has_consent_on_file
    FROM session_participants
    WHERE pseudo_id = u.pseudo_id
) sp ON TRUE
ORDER BY last_active_at DESC NULLS LAST, u.created_at DESC;
```

(If `session_participants.joined_at` is not populated across the
board, substitute `sessions.started_at` via an extra join. The spec
is about the *shape* of the query, not the exact join tree.)

### `GET /internal/admin/users/{pseudo_id}`

Returns `AdminUserDetail`:

```rust
pub struct AdminUserDetail {
    pub user: User,
    pub latest_display_name: Option<String>,
    pub display_names: Vec<DisplayName>,
    pub sessions: Vec<ParticipatedSession>,
}

pub struct ParticipatedSession {
    pub session_id: Uuid,
    pub campaign_name: Option<String>,
    pub title: Option<String>,
    pub started_at: DateTime<Utc>,
    pub ended_at: Option<DateTime<Utc>>,
    pub status: String,
    pub consent_scope: Option<String>,
    pub data_wiped_at: Option<DateTime<Utc>>,
}
```

Kept as a single fetch so the detail page doesn't fire six
round-trips. Display name list reuses `display_names::list`.

### `PATCH /internal/users/{pseudo_id}` — existing, audit it

Already accepts `{ is_admin }`. Verify that flipping the admin
flag writes an `audit_log` entry keyed on the caller's
`ServiceSession` + the target `pseudo_id`. Add if missing.

## Portal shape

### `src/app/admin/users/page.tsx` (master)

Server component. Fetches via a new BFF route
`GET /api/admin/users` → enriched list. Renders a table with
sticky header, status-badge filter chips, text search that filters
client-side (≤500 users is the order of magnitude for a while).

### `src/app/admin/users/[pseudo_id]/page.tsx` (detail)

Server component. Fetches via `GET /api/admin/users/:id`. Renders
the four sections above. The admin-toggle lives here as a client
component that opens a shadcn `<AlertDialog>` on click.

### `src/app/api/admin/users/[pseudo_id]/route.ts`

Add `GET` alongside the existing `PATCH`.

## Migration

None. Schema is unchanged; we're only reading existing columns
differently.

## Rollout

1. Land data-api changes: extend list route, add detail route. CI
   green → merge → `:branch-main` on dev auto-pulls.
2. Verify dev with curl + existing Rust tests.
3. Land portal changes: new BFF routes, replace the current
   `user-row.tsx` flat list with master/detail pages. Smoke:
   list shows names, detail page loads, admin toggle still works,
   toggle is audit-logged, toggling self is disabled.
4. Remove the old `UserRow` component once nothing imports it.

Prod deploy is by explicit `v*` tag on data-api + portal, same as
every other ship path. Watch `ops-followups.md #68` re: prod's
`:dev` tag mode.

## Non-goals (now)

- Impersonation / view-as-user.
- Role schemes beyond `is_admin` / not-admin.
- Bulk admin operations.
- Export of the users list (CSV/JSON).
- Email notifications of admin promotion.
- An `/admin/sessions` master/detail — separate surface, separate
  spec. The sessions list at `/sessions` already covers most of
  what an admin needs there.
