# sessionhelper-hub

Umbrella repo for the Session Helper / Open Voice Project family — a small, minimalist project building a consent-first TTRPG voice dataset and the infrastructure around it.

This repo is the **published, public** hub. It documents org-wide conventions, architecture decisions, and the legal/infra journey for anyone traveling a similar path (forming an LLC, picking a hosting provider, shipping a Rust Discord bot, etc). Specific operational details (IPs, credentials, filing numbers) live in a **local-only private companion repo** on the maintainer's machine and are never published.

## What lives here

| Path | Contents |
|---|---|
| `SPEC.md` | OVP program spec — mission, stakeholders, goals, non-goals, success criteria, milestones, traceability. The strategic layer above `ARCHITECTURE.md`. |
| `CLAUDE.md` | Org-wide conventions — Rust code style, git workflow, comment philosophy, shared-secret auth model, public/private repo distinction. Each sibling service repo's slim `CLAUDE.md` points here. |
| `ARCHITECTURE.md` | Cross-service architecture and data flow for the OVP + chronicle-bot stack. |
| `legal/README.md` | Abstract journey notes on incorporating a single-member LLC, picking a state, registered agents, banking setup. No personal info. |
| `infra/README.md` | Abstract journey notes on hosting choices (why Hetzner, why two VPSes, how the compose stack is shaped, how CI/CD works, how secrets are stored). No IPs or credentials. |
| `infra/dev-compose.yml` | Canonical docker-compose file for the OVP stack. Uses env var placeholders; real values come from a `.env` file generated from `pass` at deploy time. |
| `design/uncodixfy-ui.md` | UI rules for the participant portal — warm, editorial, honest. Linear/Raycast/Stripe, not generic AI dashboard. |

## Sibling repos (not submodules)

All active code lives in independent sibling repos:

- `chronicle-data-api` — Rust, storage abstraction (Postgres + S3)
- `chronicle-pipeline` — Rust, transcription library (VAD + Whisper + operators)
- `chronicle-worker` — Rust, pipeline orchestrator
- `chronicle-bot` — Rust, Discord bot (voice capture with consent)
- `chronicle-portal` — Next.js/TS participant portal

## For travelers on a similar path

If you're setting up a similar project — a small consent-first dataset project, or any small Rust service you want to run cheaply with real structure — the two docs to start with are:

- [`legal/README.md`](legal/README.md) — how we incorporated, why New Mexico, what we skipped, what we'll do later
- [`infra/README.md`](infra/README.md) — why Hetzner, how we separated dev and prod, how the service architecture fits together, how we do CI/CD and secrets

Both are explicitly written to be skimmed for decisions and tradeoffs, not copy-pasted.
