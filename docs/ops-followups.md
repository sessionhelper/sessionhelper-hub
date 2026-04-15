# Ops followups

Running list of deploy / infra hygiene items that aren't tests. Each
entry: what the gap is, why it's tolerable for now, the signal that
says "time to fix it."

Status legend: `[ ]` = not started, `[~]` = in progress, `[x]` = done.

---

## [ ] Image pins: stop rolling `:dev` for tagged releases

**The gap.** `infra/prod-compose.yml` pins both `data-api` and
`collector` to the `:dev` tag. The deploy workflow builds on every
push and also builds on `v*` tags, but either way it just overwrites
`:dev` in ghcr. So a `git tag v0.9.0` doesn't pin anything — the next
`main` push can replace what prod is running without a new tag.

**Why it's tolerable.** Nothing on prod is a real release yet. The
only current user is me. Rolling `:dev` means I can ship a hotfix
from `main` without re-tagging, which is the right trade-off for
Phase 0 when we're still stabilising voice.

**Fix signal.** First time I want to say "prod is on v0.9.0 and dev
is one ahead" and actually mean it. Probably when external testers
land, or when a rollback matters (i.e. we ship something and need
to bounce back to the previous known-good tag). At that point:

- `prod-compose.yml` pins to a specific `:vX.Y.Z` tag.
- Deploy workflow's SSH step writes the tag into the compose file
  (or env) before `docker compose up -d`, so the pin follows the
  release being deployed.
- Keep `:dev` rolling for the dev VPS, separately.

Noted 2026-04-15 after the v0.2.0-rc3 / v0.9.0 deploy — the tagged
images landed, but only because `:dev` had just been rewritten with
the same bits. Not a guarantee going forward.

---

## [x] Zombie-bot check before live testing

**The gap.** A stale locally-built bot process (`target/release/ttrpg-collector` from Apr 4) kept running for 11+ days using the dev Discord token, and was acking interactions in parallel with the actual dev-VPS bot. Symptoms: user sees responses from the old codebase (e.g. the "Need at least 2 people" string that was since removed) while the live bot's ack returns `404 Unknown interaction` because the zombie won the ack race.

**Countermeasure.** `sessionhelper-hub/scripts/check-zombies.sh` walks `ps axo` for any process matching `ttrpg-collector` / `chronicle-bot` binary paths (including old pre-rename paths) and reports them. Run with `--kill` to terminate. Lives in the hub because it's cross-repo ops hygiene, and because `chronicle-bot/scripts/` is gitignored.

**Fix signal.** Before any interactive test session, run
```
bash sessionhelper-hub/scripts/check-zombies.sh
```
If it reports anything, kill those before firing `/record`. Consider wiring it into the E2E test harness preflight.

Noted 2026-04-15 after the zombie ate a full debugging evening's worth of interactions.

---

(Add new entries above this line.)
