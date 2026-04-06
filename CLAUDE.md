# sessionhelper-hub — Org-wide conventions

This file is the canonical source for conventions shared across every sibling repo in the Session Helper / Open Voice Project family. Each sibling repo's `CLAUDE.md` is slim and points here for anything cross-cutting. See `ARCHITECTURE.md` for how the services fit together.

## Public vs private hub

There are **two hub repos**. This file lives in the public one.

| Repo | Location | Contents | Published |
|---|---|---|---|
| `sessionhelper-hub` (this file) | `/home/alex/sessionhelper-hub/` | Org-wide conventions, architecture, compose shape, design system, abstract legal + infra journey docs | **Yes — public GitHub** |
| `sessionhelper-hub-private` | `/home/alex/sessionhelper-hub-private/` | VPS addresses, SSH users, credentials catalog, LLC filing details, banking plans, internal workflow skills (sh-\*, check-sh-\*, nm-sos-\*, peon-ping-\*) | **No — local-only, never pushed** |

**Hard rules:**

- **This repo is publishable.** Anything committed here will be (or has been) visible to anyone. Before committing, scan for IPs, hostnames, bot tokens, DB credentials, S3 keys, emails, phone numbers, filing numbers, EIN, and any mention of real user identities.
- **Never inline content from the private hub into this one.** Reference by relative path when context is needed (e.g. "see the private hub's infra notes"). Do not copy lines across.
- **New sensitive content goes straight to the private hub.** If you're about to document a VPS IP, a credential path, or a business filing detail, ask: should this be public? If the answer is no or maybe, write it in the private hub.
- **When reading for context**, read both hubs — the private one is authoritative for infra/deployment/legal questions. The public one is authoritative for conventions, architecture, and design.
- **If sensitive content ever slipped into a pushed commit on this repo**, rotate every credential mentioned in it immediately and rewrite history.

## Sibling repos

| Repo | Role |
|---|---|
| `ovp-data-api` | Storage abstraction — Postgres + S3. The only service that touches either. |
| `ovp-pipeline` | Rust library — PCM in, transcript segments out. VAD → Whisper → operators. |
| `ovp-worker` | Polls Data API, runs pipeline, posts segments back. |
| `ttrpg-collector` | Discord bot — captures per-speaker audio with consent, uploads chunks. |
| `ttrpg-collector-feeder` | Dev-only feeder bot fleet — joins voice and plays WAVs for E2E testing. |
| `ttrpg-collector-frontend` | Next.js participant portal — consent, transcript review, data export. |

## Rust code style

Follow [Rust Design Patterns](https://rust-unofficial.github.io/patterns/) and [Rust API Guidelines](https://rust-lang.github.io/api-guidelines/).

**Patterns:**
- `Result` + `?` for error propagation. Keep the happy path flat, no nested `if`/`match` chains.
- Enums with data for state machines. Match on state; don't `if`-check scattered fields.
- Iterators over index-based loops. Use `filter`, `map`, `for_each`.
- Typestate pattern when invalid transitions should be compile errors.
- Avoid premature abstraction — three similar lines beats a premature generic.

**Anti-patterns (don't do these):**
- No deeply nested `if`-statements — flatten with early returns and `?`.
- No stringly-typed state — use enums.
- No scattered state across multiple `HashMap`s — use a struct that owns its data.
- No manual mutex juggling for hot paths — use channels.

## Comment & doc philosophy

- Comments explain **why**, not what. Every public function has a brief doc comment explaining purpose and rationale.
- Complex logic blocks get inline comments, especially for: Discord API quirks, timing constraints, error handling decisions.
- Keep comments concise but sufficient for a first-time reader.

## Git workflow

All repos use the same trunk-based flow:

```
feature/* → dev (--no-ff) → main (--no-ff) → tag vX.Y.Z → CI/CD
```

- **main** — production. Only receives merges from `dev`. Tag to deploy.
- **dev** — integration. Feature branches land here first.
- **feature/*** — branch from `dev`, merge back via `--no-ff`.

Never commit directly to `main` or `dev`. Never merge feature branches directly to `main`.

## Shared-secret service auth

All internal service-to-service auth uses the same model (implemented in `ovp-data-api`, used by every other Rust service):

1. A `SHARED_SECRET` env var is set on every service in the deployment.
2. Clients `POST /internal/auth` with `{ "shared_secret": "...", "service_name": "..." }` and get back a session token.
3. Clients send `Authorization: Bearer <session_token>` on every subsequent request.
4. Clients send a heartbeat to `/internal/heartbeat` every 30 seconds.
5. Server reaps sessions inactive >90 seconds.

No file-based tokens, no rotation — just the shared secret. Containers share it via env.

## Pseudonymization

Discord user IDs are pseudonymized with unsalted SHA-256, first 8 hex chars:

```rust
let pseudo = &hex::encode(Sha256::digest(discord_id.to_string().as_bytes()))[..8];
```

No salt — voice is identifiable in the recordings anyway, the pseudonymization is for database keys and consent audit trails, not privacy against recovery.

## Environment and secrets

- Secrets live in [`pass`](https://www.passwordstore.org/) on the maintainer's machine. The specific entry catalog is tracked in the private hub, not here.
- `.env` files are gitignored in every repo. `.env.example` templates are committed.
- Production deploys use env files chmod 600, never files committed to repos.

## Design system

UI work in `ttrpg-collector-frontend` (and any future frontend) follows the **Parchment** visual language and the Uncodixfy rules. See `design/uncodixfy-ui.md` for the full ruleset. The tl;dr:

- Warm, editorial, honest. Linear/Raycast/Stripe, not generic AI dashboard.
- No oversized rounded corners, no soft gradients, no hero sections inside dashboards, no decorative copy.
- Crimson Pro (serif) for headings/body, Inter (sans) for UI/nav/metadata.
- Simple cards (1px borders, 4px radius), buttons solid or ghost, centered max-width content.

## Memory and persistence

- Each sibling repo has its own project memory under `~/.claude/projects/-home-alex-<repo>/memory/`.
- Cross-cutting facts that are **architectural or conventional** (shared auth model, design system rules, code style, git workflow) live in this hub.
- Cross-cutting facts that are **operational or sensitive** (LLC status, VPS details, credential catalog) live in the private hub.
- Don't duplicate either hub's content into per-repo memory — link to the appropriate hub instead.

## Long-running work

Long-running actions — image builds, cross-repo refactors, multi-step investigations, anything that will run for more than ~30 seconds without user input — should kick off in a **background agent task** (subagent spawn with `run_in_background: true`, or an Agent tool call). The main thread stays open for conversation and quick iteration while the agent works.

Rules of thumb:

- **Kick off in background**: docker image builds (`cargo build --release` → 2–5 minutes), full-repo cleanups, "read the whole codebase and propose X" research tasks, multi-file refactors the user has already approved the shape of, long test runs.
- **Keep in foreground**: interactive debugging, single-file edits, anything where the next step depends on seeing the output, ambiguous user requests that need clarification before executing.
- **Report when done**: when a background task completes, surface the result to the user concisely. Don't bury the outcome in a wall of text — lead with the headline.
- **Don't poll**: when a background task is running, don't check on it every 5 seconds. The harness will notify when it completes. Keep talking to the user about other things in the meantime.

The goal is to avoid dead air. If the user has to wait on Claude while Claude is waiting on a build, something is mis-structured.
