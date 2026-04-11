# sessionhelper-hub

Umbrella repo for the Session Helper / Open Voice Project family — a small, minimalist project building a consent-first TTRPG voice dataset and the infrastructure around it.

This repo is the **published, public** hub. It documents org-wide conventions, architecture decisions, and the legal/infra journey for anyone traveling a similar path (forming an LLC, picking a hosting provider, shipping a Rust Discord bot, etc). Specific operational details (IPs, credentials, filing numbers) live in a **local-only private companion repo** on the maintainer's machine and are never published.

## What lives here

| Path | Contents |
|---|---|
| [`SPEC.md`](SPEC.md) | OVP program spec — mission, stakeholders, goals, non-goals, success criteria, milestones, traceability. The strategic layer above `ARCHITECTURE.md`. |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Cross-service architecture and data flow for the Chronicle toolchain. |
| [`CLAUDE.md`](CLAUDE.md) | Org-wide conventions — Rust code style, git workflow, comment philosophy, shared-secret auth model, public/private repo distinction. Each sibling service repo's slim `CLAUDE.md` points here. |
| [`legal/README.md`](legal/README.md) | Abstract journey notes on incorporating a single-member LLC, picking a state, registered agents, banking setup. No personal info. |
| [`infra/README.md`](infra/README.md) | Abstract journey notes on hosting choices (why Hetzner, why two VPSes, how the compose stack is shaped, how CI/CD works, how secrets are stored). No IPs or credentials. |
| [`infra/dev-compose.yml`](infra/dev-compose.yml) | Canonical docker-compose file for the full dev-VPS stack (postgres + data-api + bot + worker + 4 feeders). |
| [`infra/prod-compose.yml`](infra/prod-compose.yml) | Canonical docker-compose file for the prod VPS (postgres + data-api + bot only). Fetched by the deploy workflows at runtime. |
| [`docs/dave-bot-ecosystem.md`](docs/dave-bot-ecosystem.md) | Ecosystem map of every Discord DAVE-supporting bot and library, the shared multi-user decrypt bug, and the collaborator tree. |
| [`design/uncodixfy-ui.md`](design/uncodixfy-ui.md) | UI rules for the participant portal — warm, editorial, honest. Linear/Raycast/Stripe, not generic AI dashboard. |

## Naming scheme

Three layers, each owning a distinct concept:

- **OVP** (Open Voice Project) — the open TTRPG voice dataset itself. Preserved in identifiers that describe *data*: Postgres user/db (`ovp`, `ovp_data_api`), bridge network (`ovp`), volume (`ovp-postgres`), VPS path (`/opt/ovp`), S3 buckets (`ovp-dataset-raw`, `ovp-dataset-dev`).
- **Chronicle** — the evolving toolchain (capture bot, storage, pipeline, portal) that produces OVP data. Used for repo names, crate names, binary names, image paths, systemd units.
- **Session Helper** — Session Helper LLC is the legal wrapper. A future consumer-facing Session Helper app will inherit from the Chronicle foundation. The `sessionhelper` GitHub org name preserves this identity.

## Sibling repos (not submodules)

All active code lives in independent sibling repos:

- [`chronicle-bot`](https://github.com/sessionhelper/chronicle-bot) — Rust, Discord bot (voice capture with consent, DAVE E2EE)
- [`chronicle-data-api`](https://github.com/sessionhelper/chronicle-data-api) — Rust, storage abstraction over Postgres + Hetzner Object Storage
- [`chronicle-worker`](https://github.com/sessionhelper/chronicle-worker) — Rust, event-driven pipeline orchestrator
- [`chronicle-pipeline`](https://github.com/sessionhelper/chronicle-pipeline) — Rust library, VAD → Whisper → scene/beat operators
- [`chronicle-portal`](https://github.com/sessionhelper/chronicle-portal) — Next.js 15 / React 19 participant portal with BFF auth + SSE bridge
- [`chronicle-feeder`](https://github.com/sessionhelper/chronicle-feeder) — Rust, dev-only E2E test harness feeder bot (four Piper TTS voices)
- [`chronicle-api`](https://github.com/sessionhelper/chronicle-api) — Rust, dormant public API gateway (see that repo's README)

## For travelers on a similar path

If you're setting up a similar project — a small consent-first dataset project, or any small Rust service you want to run cheaply with real structure — the two docs to start with are:

- [`legal/README.md`](legal/README.md) — how we incorporated, why New Mexico, what we skipped, what we'll do later
- [`infra/README.md`](infra/README.md) — why Hetzner, how we separated dev and prod, how the service architecture fits together, how we do CI/CD and secrets

Both are explicitly written to be skimmed for decisions and tradeoffs, not copy-pasted.
