# OVP — Program Spec

**Status:** Phase 0 — voice capture broken, working on reliability
**Ownership:** Session Helper LLC, sole operator
**Scope:** The Open Voice Project (OVP) data collection program and the Chronicle toolchain that produces it
**Last reviewed:** 2026-04-11

---

## 1. Identity

**One-line pitch:** Build a toolchain and collect a dataset of TTRPG session audio to develop the future Session Helper application, and publish a subset as open data under CC BY-SA 4.0.

**What this doc is:** The strategic layer that sits above `ARCHITECTURE.md`. Architecture describes *how the bits move.* This spec describes *what the program is and how we know it's working.*

**Naming:**

- **OVP** — Open Voice Project. The open TTRPG voice dataset.
- **Chronicle** — The evolving toolchain (capture bot, storage, pipeline, portal) that produces OVP data and will carry forward into the future Session Helper application.
- **Session Helper** — The future user-facing product. Not yet built. The current Chronicle work is its foundation.
- **Session Helper LLC** — The legal entity that owns all of the above.

See `README.md` for the repo layout under this naming scheme.

---

## 2. Stakeholders

### Primary stakeholder

**The user** (Alex Camilo, operator of Session Helper LLC). Sole decision-maker, sole developer, sole admin. Needs:

- A dataset of TTRPG session audio + transcripts to develop the future Session Helper application
- A working toolchain that produces that dataset with minimum ongoing effort
- An eventual user-facing product (Session Helper) built on the Chronicle foundation

### Contributors (not stakeholders)

**Consenting players and GMs in recorded sessions.** They are *not* stakeholders in a product-management sense — they do not drive requirements. They are **contribution targets** who must be enticed to opt in. The program succeeds or fails on whether the utilities offered to contributors are valuable enough to make them opt in.

Utilities offered to contributors:

- Session audio download (their own tracks)
- Transcript download + editing
- Supplemental metadata attachment (character names, session notes, corrections)
- Full consent and deletion controls (opt-in, opt-out, LLM-training opt-out, public-release opt-out)
- Pseudonymous identity (SHA-256 first-8 per `CLAUDE.md` pseudonymization rule)

**The contribution-incentive bar is a first-class design constraint**, not a nice-to-have. G2 (toolchain UX) is partly in service of this bar.

### Session Helper LLC

Legal wrapper holding all the work. Not a stakeholder in a product-management sense. Holds the GitHub org, domains, LLC structure, legal filings. Administered by the user.

---

## 3. Mission

### Primary

**Collect a large dataset of TTRPG session audio + transcripts to refine and develop the future Session Helper application.**

The toolchain (Chronicle) is the foundation of that future application. Building it now, and using it to collect real data, *is* the first iteration of developing the product.

### Secondary

**Publish a subset of OVP as open data under CC BY-SA 4.0 on HuggingFace**, with per-speaker tracks, pseudonymized identities, LLM-training opt-outs honored, and a documented schema. This is a first-tier goal (G5), not a downstream side effect.

### Why TTRPG audio specifically

- **Dialogue density.** Sessions are mostly speech with minimal filler.
- **Multi-speaker dynamics.** Natural interruptions, overlap, turn-taking, backchanneling.
- **Character voice variety.** Players do voices; one speaker generates many voice profiles.
- **Long-form sessions.** 3-4 hour sessions produce hours of coherent conversation in one capture.
- **Consenting communities.** Tabletop communities are accustomed to recording for podcasts and already understand consent flows.

### Why consent-first

- **Ethical baseline.** Voice is biometric. Recorded voice is a durable signal of identity. Consent must be informed, revocable, and auditable end-to-end.
- **Legal baseline.** Jurisdictional consent laws vary (two-party consent, GDPR, CCPA). Per-speaker explicit consent with a working deletion pipeline is the only posture that holds up across jurisdictions.
- **Dataset quality.** Consent is the signal that separates this dataset from scraped-from-YouTube alternatives. Researchers who care about provenance will care about this.

### Why per-speaker

- **Reusability.** Per-speaker tracks enable diarization, speaker separation, character-voice studies, multi-speaker conversation analysis, and countless downstream tasks that mixed tracks cannot.
- **Per-speaker consent.** One speaker can opt out without losing the whole session.

---

## 4. High-level goals

Ordering is intent, not strict dependency. G1 is the current phase blocker; G5 is the furthest-downstream goal but still first-tier.

### G1 — Reliable voice capture

The Chronicle bot must capture per-speaker audio through DAVE E2EE without losing packets, dropping users, or failing on multi-user join.

*This is the current Phase 0 blocker.* The ecosystem-wide MLS proposal clearing race (see `docs/dave-bot-ecosystem.md`) affects every davey-based bot. We ride `songbird` DAVE branch + `Snazzah/davey` and are exercising code with <2 weeks of production history and one author. The OP5-triggered reconnect heal is prototyped as the primary mitigation.

Nothing else ships until this does.

### G2 — Toolchain UX for three roles

A working user-facing application with distinct flows for:

- **GMs** — start/stop recording, session management, post-session review
- **Players** — review their own data, edit transcripts, download audio, manage consent, delete. *This is also where the contribution-incentive bar gets met.*
- **Admin** (the user) — annotate sessions, validate pipeline output, quality-score, curate dataset candidates

### G3 — Transcription + beat/scene extraction on real data

The `chronicle-pipeline` must run end-to-end on real captured sessions, producing transcription accurate enough for editing and beat/scene boundaries that the admin can validate against personal annotation.

**Anchor sessions:** the planned Phase 2 volunteer oneshot (4 weeks out, design at `/home/alex/data_collection_oneshot/`) and an already-consented DH2e excerpt from the user's own party.

**Lore extraction is explicitly deferred** to the future Session Helper app. It lives in `sessionhelper-legacy` as Python code and is not part of Chronicle. Beat and scene extraction *are* in scope.

### G4 — Robust testing pipeline for the recording bot

The DAVE bug class demands it. Regression tests against recorded and synthetic captures, multi-user scenarios, reconnect scenarios, OP5-triggered heal validation. `chronicle-feeder` is the existing E2E test harness and needs to grow meaningfully beyond its current scope.

### G5 — Public CC BY-SA 4.0 dataset release on HuggingFace

First-tier goal. A meaningful first drop of the OVP dataset published under CC BY-SA 4.0 with:

- Per-speaker audio tracks
- Pseudonymized identities (SHA-256 first-8 per CLAUDE.md)
- Documented dataset schema (frozen at release time)
- LLM-training opt-outs honored (segments marked `no_llm_training` excluded)
- Public-release opt-outs honored (segments marked `no_public_release` excluded)
- Documented consent trail per segment

Requires legal analysis on character voice IP, inadvertent capture of third-party material, and CC BY-SA 4.0 compatibility with the consent envelope.

### G6 — Sustainable operational footprint

One-person-runnable. Cloud infrastructure stays at hobby/indie scale. No manual scaling. Secrets via `pass`. Dev and prod separable. Monthly cost stays under a committed ceiling (currently ~€8/month per `infra/README.md`; target: under €25/month sustained through Phase 3).

---

## 5. Non-goals

These are deferred, excluded, or out of scope. Non-goals are load-bearing — without them, scope will drift.

### NOT lore extraction

Entity/NPC/location/item extraction, lore wiki, campaign companion features. These belong to the future Session Helper app, not to Chronicle. The Python-era `sessionhelper-legacy` implementation of these features stays archived for reference; a future Rust rewrite happens when the program reaches that phase.

### NOT paid tiers or monetization

No pricing, billing, customer onboarding, or paid gating while the Phase 0 voice capture blocker exists. Monetization is a distant-future question conditional on the future SH app being built.

### NOT productizing for external users yet

The user is the only admin. External GMs running sessions through Chronicle as a closed-beta product is a Phase 3+ goal, not a current one. The Chronicle portal allows *contributors* to review their own data — that's different from productizing.

### NOT responsible for upstream DAVE fixes

Chronicle depends on `davey` and `songbird` but does not own fixing the wider Discord DAVE ecosystem's MLS proposal race. Workarounds in our code are fair game; upstream patches are a contribution (welcome, not committed to). See `docs/dave-bot-ecosystem.md` for the full ecosystem map.

### NOT tied to a single game system

D&D 5e, Daggerheart 2e, Pathfinder, PbtA, OSR, etc. — all welcome as data sources. System-specific features belong to the future Session Helper app.

### NOT a public-first or community-driven dataset project

The user is the program driver. Data flows to the user's application first. Public release is a goal (G5) but not the primary purpose. Contributors are incentive targets, not co-owners.

### NOT a transcription service for hire

Not offering transcription as a product to third parties. The `chronicle-pipeline` is a means to a dataset, not a SaaS.

### NOT a model training effort

Chronicle produces a dataset. Researchers and the future Session Helper app train models on it. Training model weights is out of scope for OVP itself.

---

## 6. Mid-level objectives

Each high-level goal broken into concrete, scoped objectives.

### G1 → Reliable voice capture

- **O1.1** — Reproduce the multi-user DAVE decrypt-failure bug with a minimal, scripted test case in `chronicle-feeder`.
- **O1.2** — Ship the OP5-triggered reconnect heal to production `chronicle-bot` and verify it catches the failure class in the reproducer.
- **O1.3** — Verify zero-loss capture across a 4-hour multi-user session in a realistic configuration (>= 4 speakers, MLS transitions triggered).
- **O1.4** — Document a fallback-to-Craig path for critical sessions where our bot's reliability isn't trusted yet.

### G2 → UX for three roles

- **O2.1 GM flow:** `/record` → consent → recording → `/stop` → session appears in the portal, ready for review.
- **O2.2 Player flow:** Discord OAuth login → review own segments → play audio → read/edit transcript → download artifacts → toggle consent/opt-outs → delete if desired.
- **O2.3 Admin flow:** quality-score a session, annotate ground truth, export annotated segments, mark segments as dataset candidates.
- **O2.4 Contribution-incentive utilities:** session audio download, transcript download (txt and structured JSON), supplemental info attachment — demonstrable as "why would a player opt in" features.

### G3 → Pipeline on real data

- **O3.1** — `chronicle-pipeline` runs end-to-end on the Phase 2 oneshot capture without manual intervention.
- **O3.2** — Beat and scene boundaries manually validated against user annotation of the same capture; measure agreement.
- **O3.3** — Document the pipeline validation loop so future sessions are processed with the same rigor.
- **O3.4** — Decide whether beat/scene thresholds need tuning based on empirical data from at least two real sessions.

### G4 → Testing pipeline for the bot

- **O4.1** — Extend the `test-data/` capture corpus with edge cases derived from real DAVE failures (multi-user joins at epoch boundaries, reconnect-heal triggers, padding packets, Cloudflare-voice-server decryption quirks).
- **O4.2** — CI runs regression tests against synthetic captures on every `chronicle-bot` PR.
- **O4.3** — Multi-user join scenario is covered by an integration test that can run locally via `chronicle-feeder`.
- **O4.4** — DAVE MLS proposal race has a targeted reproduction test — not just "some sessions fail."

### G5 → Public dataset release

- **O5.1** — Freeze the v1 dataset schema: per-speaker audio format, metadata columns, consent event linkage, license file.
- **O5.2** — Complete legal review: CC BY-SA 4.0 compatibility with the consent envelope; character voice IP analysis; inadvertent third-party capture handling; jurisdiction review.
- **O5.3** — Publish v1 release to HuggingFace with ≥X hours (X defined in §7 success criteria).
- **O5.4** — Announce the release and verify at least one third-party researcher successfully consumes it and reports back.

### G6 → Sustainable operational footprint

- **O6.1** — Monthly infra cost tracked and stays under €25/month through Phase 3.
- **O6.2** — No manual service restarts required for routine capture. The deploy pipeline is fully automated for `chronicle-data-api`, `chronicle-bot`, and `chronicle-feeder` (currently the three repos with deploy workflows).
- **O6.3** — Dev and prod VPSes are structurally isolated. No production data leaks into dev flows.
- **O6.4** — Secrets managed via `pass` per the `CLAUDE.md` convention, never committed.
- **O6.5** — Storage cost ceiling: Hetzner Object Storage costs stay predictable; alert on unexpected growth.

---

## 7. Verifiable success criteria

Three pillars, one cross-cutting dimension. This section is a collaborative workshop item — v0.1 below, to be tightened as real data comes in.

### A. Recording bot — functional via robust testing pipeline

- **A.1** Multi-user DAVE session captures all speakers for ≥4 hours with no session death. *(G1, G4)*
- **A.2** Packet loss rate during MLS transitions below a committed threshold. *Target TBD — measured empirically from the reproducer.*
- **A.3** Reconnect heal fires and recovers within N seconds of failure. *N TBD — currently "anecdotally fast."*
- **A.4** CI regression suite on `chronicle-bot` green across the synthetic capture corpus.
- **A.5** `chronicle-feeder` can script the multi-user failure reproduction on demand.

### B. UI/UX functional for all three roles

- **B.1** GM walkthrough: start session → `/record` → stop session → view results → zero GM-side errors.
- **B.2** Player walkthrough: Discord OAuth → review segments → edit transcript → download → consent toggles → delete → zero player-side errors.
- **B.3** Admin walkthrough: annotate → validate pipeline output → export → mark for dataset → zero admin-side errors.
- **B.4** Each walkthrough documented as a reproducible checklist in `chronicle-portal/docs/`.
- **B.5** Contribution-incentive bar validated: at least one external contributor (beyond the user's immediate circle) opts in unprompted after seeing the portal.

### C. Cloud infrastructure functional

- **C.1** Sessions ingested, processed, and stored without manual intervention on the dev VPS.
- **C.2** Dev and prod VPSes verifiably isolated; prod data never appears in dev logs.
- **C.3** Monthly infra cost under €25 sustained through Phase 3.
- **C.4** All secrets managed via `pass`; zero secrets in git history (audited).
- **C.5** `chronicle-data-api.service` systemd unit survives reboots and recovers from transient docker failures.

### Cross-cutting: consent & ethics

- **X.1** 100% of released segments have a traceable consent event in the audit log.
- **X.2** End-to-end opt-out workflow: a contributor can request deletion, the system honors it within N days, and a post-hoc audit confirms the data is gone from all stores. *N = 30 for first cut, tighten to 7 days at Phase 3.*
- **X.3** Pseudonymization enforced at ingest per the SHA-256 first-8 rule in `CLAUDE.md`.
- **X.4** No PII in the released dataset per audit — names, Discord IDs, location data all stripped or pseudonymized.
- **X.5** Released dataset is accompanied by a dataset card documenting consent, licensing, known limitations, and intended use cases.

---

## 8. Milestones and phases

Each phase has a single focused exit criterion. Phases do not overlap — the program finishes one before starting the next.

### Phase 0 — Voice reliability (CURRENT)

**Focus:** Fix the DAVE-ecosystem MLS proposal clearing race that breaks multi-user capture.

**Exit criterion:** `chronicle-bot` captures a clean multi-user 4-hour session with no session death, no unexplained packet loss, and verified OP5-triggered reconnect heal. Reproducer in `chronicle-feeder` exists and passes.

**Does not exit on:** UI polish, dataset work, new pipeline features, SPEC.md revisions.

**Active risks:** see §11 — DAVE/davey maturity is the entire phase blocker.

### Phase 1 — UX for three roles

**Focus:** GM, player, and admin walkthroughs all work end-to-end on Phase 0 infrastructure.

**Exit criterion:** Each walkthrough from §7 (B.1, B.2, B.3) completes without error. Contribution-incentive utilities (session download, transcript download) functional for players.

### Phase 2 — End-to-end pipeline validation on real data

**Focus:** Run the full stack — capture → pipeline → portal → annotation — on a real session.

**Anchors:**

- The planned volunteer oneshot (4 weeks out, design at `/home/alex/data_collection_oneshot/`)
- The already-consented DH2e excerpt from the user's own party

**Exit criterion:** User-annotated ground truth for the oneshot exists; transcription WER measured; beat/scene extraction validated against annotation; pipeline validation loop documented.

### Phase 3 — Collection at scale

**Focus:** Sessions consistently captured, ingested, processed, and reviewed with minimal user intervention. The bottleneck becomes annotation throughput, not tooling.

**Exit criterion:** Backlog of sessions waiting for annotation (not for tooling fixes). Legal analysis for public release complete. Contribution-incentive bar validated by at least one external contributor opting in unprompted.

### Phase 4 — Public release (required, first-tier)

**Focus:** Publish OVP v1 to HuggingFace.

**Exit criterion:**

- First CC BY-SA 4.0 drop to HuggingFace with ≥X hours (X TBD during Phase 3; target likely 10-50 hours for v1)
- Documented schema, frozen for v1
- Pseudonymized identities
- LLM-training and public-release opt-outs honored
- Legal review signed off
- Dataset card published
- At least one third-party researcher consumes the release and reports back

---

## 9. How volunteer sessions plug in

### The current flow (to be built in Phases 0-2)

1. GM + consenting players join a Discord voice channel.
2. GM runs `/record` via `chronicle-bot`.
3. `chronicle-bot` captures DAVE-encrypted per-speaker audio via Songbird VoiceTick events.
4. 5MB PCM chunks upload in real-time to `chronicle-data-api` via shared-secret auth.
5. `chronicle-data-api` writes chunks to Hetzner Object Storage (`ttrpg-dataset-raw` bucket) and metadata to Postgres.
6. GM runs `/stop`; the session is finalized.
7. `chronicle-worker` picks up the session via WebSocket notification from `chronicle-data-api`, downloads chunks, runs `chronicle-pipeline` as a library.
8. Pipeline produces transcription + scene/beat segments.
9. Worker posts results back to the data-api.
10. `chronicle-portal` displays the session for participant review.
11. Contributors review, edit, set consent/opt-outs, delete if desired.
12. Admin (user) annotates, validates, and marks segments for dataset inclusion.
13. Validated segments enter the dataset candidate set.

See `ARCHITECTURE.md` for the technical details of each step.

### Phase 2 canonical anchor: the volunteer oneshot

**`/home/alex/data_collection_oneshot/`** contains the full GM prep kit for the Phase 2 anchor session: premise, setting, enemy party, session flow, combat cheat sheet, companion stat blocks, and the already-annotated narrative structure.

The oneshot is **pipeline validation first, dataset contribution second**. The user will personally annotate ground truth against the captured audio and use the comparison to measure transcription quality and beat/scene extraction accuracy.

The session's design — level-1 villagers vs. chaotic hungover adventurers in a shopping chaos comedy — was chosen explicitly for natural multi-speaker speech variety: panicked crosstalk, negotiation, deception, exasperation, and tonal whiplash. This maximizes dialogue density relative to combat silence.

### The DH2e excerpt

The user's own Daggerheart 2e home game has consented to a short excerpt being contributed as public data. This is the **first already-consented public contribution**. It fits Phase 2 (as additional validation material) and Phase 4 (as a v1 public release seed).

---

## 10. Traceability — features to implementation

The load-bearing section. Each success criterion maps to the component that implements it, the doc that specifies the how, and current status.

### A. Recording bot

| Criterion | Component | Doc | Status |
|---|---|---|---|
| A.1 4hr multi-user capture, no death | `chronicle-bot` (voice-capture/) | `docs/voice-capture-architecture.md`, `docs/voice-capture-requirements.md` | **BLOCKED** on DAVE bug class |
| A.2 Packet loss threshold | `chronicle-bot`, `chronicle-feeder` reproducer | `docs/dave-bot-ecosystem.md`, `chronicle-bot/docs/dave-audit.md` | **MISSING** — threshold not defined |
| A.3 Reconnect heal latency | `chronicle-bot` OP5 heal | `chronicle-bot/docs/dave-audit.md` | **PARTIAL** — heal prototyped, latency not measured |
| A.4 CI regression suite | `chronicle-bot/.github/workflows/ci.yml` | — | **PARTIAL** — CI exists, corpus coverage unclear |
| A.5 `chronicle-feeder` scripted failure reproduction | `chronicle-feeder` | `chronicle-feeder/README.md` | **MISSING** — currently plays pre-recorded WAVs; DAVE-failure scripting not built |

### B. UI/UX

| Criterion | Component | Doc | Status |
|---|---|---|---|
| B.1 GM flow | `chronicle-bot` slash commands + `chronicle-portal` | `chronicle-portal/docs/architecture.md` | **PARTIAL** — slash commands work, portal-side review unclear |
| B.2 Player flow | `chronicle-portal` | `chronicle-portal/docs/architecture.md` | **PARTIAL** — portal exists, not validated against contribution-incentive bar |
| B.3 Admin flow | `chronicle-portal` (admin surface) | — | **MISSING** — no admin-specific flow documented |
| B.4 Walkthroughs documented | `chronicle-portal/docs/` | — | **MISSING** |
| B.5 External contributor opts in unprompted | entire program | — | **MISSING** — Phase 3 goal |

### C. Cloud infrastructure

| Criterion | Component | Doc | Status |
|---|---|---|---|
| C.1 Auto-ingest without intervention | `chronicle-bot → chronicle-data-api → chronicle-worker` | `ARCHITECTURE.md`, `infra/README.md` | **PARTIAL** — pipeline works end-to-end on synthetic data, not validated on real sessions |
| C.2 Dev/prod isolation | Hetzner VPSes | `sessionhelper-hub-private/infra/collector.md` | **DONE** — separate VPSes, separate Discord apps, separate buckets |
| C.3 Monthly cost under €25 | Hetzner billing | `infra/README.md` | **DONE** — currently ~€8/month |
| C.4 Zero secrets in git | git history audit | `CLAUDE.md` pseudonymization + `pass` rules | **PARTIAL** — rule documented, audit not run |
| C.5 `chronicle-data-api.service` survives reboots | systemd unit on both VPSes | `chronicle-data-api/deploy/chronicle-data-api.service` | **DONE** — verified post-rename on dev and prod VPSes 2026-04-11 |

### Cross-cutting: consent & ethics

| Criterion | Component | Doc | Status |
|---|---|---|---|
| X.1 100% traceable consent events | `chronicle-data-api` (consent rows, audit log) | `ARCHITECTURE.md` consent model | **PARTIAL** — schema exists, release-time audit not run |
| X.2 End-to-end opt-out (N=30 days) | `chronicle-portal` delete flow → `chronicle-data-api` → S3 cleanup | `ARCHITECTURE.md`, `sessionhelper-hub-private/legal/privacy-policy.md` | **PARTIAL** — portal flow exists, end-to-end walk-through not validated |
| X.3 Pseudonymization at ingest | `chronicle-data-api` ingest path | `CLAUDE.md` | **DONE** — enforced at ingest |
| X.4 No PII in released dataset | release pipeline + audit | `sessionhelper-hub-private/legal/dataset-card-draft.md` | **MISSING** — no audit script yet, no release yet |
| X.5 Dataset card at release | release artifact | `sessionhelper-hub-private/legal/dataset-card-draft.md` | **PARTIAL** — draft exists in private hub |

### Traceability summary

Gaps this exercise surfaces:

- **Phase 0 blocker (A.1, A.2, A.3, A.5):** the DAVE situation is partially mitigated but not resolved. This is the program's single biggest blocker.
- **Admin UX (B.3, B.4):** no admin-specific flow, no walkthrough docs. Phase 1 work.
- **Contribution-incentive validation (B.5):** Phase 3 goal, measurement strategy undefined.
- **Release audit tooling (X.4):** no audit script exists yet to verify "no PII in release."
- **Legal analysis (O5.2):** not started; required for Phase 4.
- **Cost monitoring and alerting (C.3, O6.5):** not automated.

---

## 11. Risks and open questions

### Active risks

**DAVE / davey ecosystem maturity.** The single biggest Phase 0 risk. The collection pipeline rides on `songbird` DAVE branch (PR #291, one author, <2 weeks of production at Phase 0 start) and `Snazzah/davey` (the only non-libdave Rust implementation). The wider ecosystem has the same MLS proposal clearing race — Craig, discord.js, py-cord, jdave, clanky, hermes-agent, frizzle-phone all hit variants of the same bug. Only jdave has shipped anything close to a root-cause fix ("transition encryptor to passthrough if no key ratchet is null"). Everyone else ships symptomatic tolerance counters.

See `docs/dave-bot-ecosystem.md` for the full ecosystem map and collaborator tree.

**Mitigation:** OP5-triggered reconnect heal prototyped; fallback to Craig for critical sessions; ongoing ecosystem watch for upstream fixes.

**Contribution-incentive bar.** If the utilities offered to players (transcript download, editing, supplemental info, consent controls) aren't compelling enough, contribution supply dries up. No measurement yet. Phase 3 exit depends on validating this with at least one external opt-in.

**Annotation throughput (sole-admin bottleneck).** Every session validated in Phases 2 and 3 goes through the user. If annotation scales linearly with session count, the program caps out fast. The pipeline has to be good enough that annotation is a minor tax per session, not the main cost.

**Contributor supply beyond immediate circles.** Phase 0-2: user's communities (oneshot cast, DH2e party, the user). Phase 3+: needs a broader contributor pipeline. No strategy yet.

**Legal — CC BY-SA 4.0 + character voices + inadvertent IP capture.** For G5 (public release), this needs real analysis. Questions: What is CC BY-SA-able when players voice copyrighted characters? What if a stream rips copyrighted music mid-session? What's the jurisdiction stance on biometric voice data in each contributor's country? All deferred to Phase 3 work.

**Hosting cost drift.** Hetzner Object Storage is cheap but one bad month of storage bloat changes that. Need a concrete ceiling (O6.5) and an alert. Not implemented.

**GHCR package transition post-rename.** After the ovp-*/ttrpg-collector-* → chronicle-* rename, old package paths still exist in GHCR and new builds need tagged releases before the new paths populate. Transition window during which compose files must point at old paths. Documented, not fully resolved.

### Open questions

- **Target dataset size for v1 release (O5.3).** 10? 50? 100 hours? Needs empirical data from Phase 2 and 3 to calibrate.
- **Quality thresholds for success criteria A.2 (packet loss) and A.3 (heal latency).** Unmeasured; baseline needs to be established.
- **Contribution-incentive validation metric (B.5).** "At least one external contributor opts in unprompted" is a binary success gate but not a continuous metric.
- **Deletion SLA (X.2).** Currently set at 30 days; Phase 3 tightens to 7 days — verify this is achievable.
- **Legal review budget and timeline.** Unknown. Phase 3 dependency.

---

## 12. What this spec does not cover

Pointers to other docs for content that lives elsewhere:

- **Architecture, data flow, service topology** → `ARCHITECTURE.md`
- **Code conventions, Rust style, git workflow, secrets management** → `CLAUDE.md`
- **Hosting, VPS configuration, deploy pipeline** → `infra/README.md`, `sessionhelper-hub-private/infra/collector.md`
- **Legal filings, LLC structure, banking** → `legal/README.md`, `sessionhelper-hub-private/legal/`
- **Design system, UI rules** → `design/`
- **Capture bot DAVE internals** → `chronicle-bot/docs/dave-audit.md`, `docs/dave-bot-ecosystem.md`
- **Pipeline stages** → `chronicle-pipeline/docs/architecture.md`
- **Voice capture requirements** → `docs/voice-capture-requirements.md`
- **The Phase 2 volunteer oneshot** → `/home/alex/data_collection_oneshot/`

---

## Appendix — revision log

- **2026-04-11** — v0.1 initial draft. Written after the ovp-*/ttrpg-collector-* → chronicle-* rename (PRs merged same day). Traceability reflects post-rename state.
