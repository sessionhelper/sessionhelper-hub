# Ops followups

Running list of deploy / infra hygiene items that aren't tests. Each
entry: what the gap is, why it's tolerable for now, the signal that
says "time to fix it."

Status legend: `[ ]` = not started, `[~]` = in progress, `[x]` = done.

---

## [x] Image pins: dev-compose at `:branch-main`, prod-compose at `:dev`

**The gap (original framing — was wrong).** I thought `:dev` was being
overwritten on every push. It wasn't: the deploy workflow only pushes
`:dev` on `refs/tags/v*`. `main` pushes only get `:sha-<short>` and
`:branch-main`. Because both dev-compose and prod-compose pointed at
`:dev`, dev couldn't roll ahead of prod, and **any merge-to-main was
invisible until someone cut a version tag.** This ate a full day of
testing on 2026-04-15: every /record test against the "deployed" fixes
was actually against the previous v-tag build.

**Fix (landed 2026-04-15).** `sessionhelper-hub/infra/dev-compose.yml`
now pins every built service to `:branch-main` instead of `:dev`. The
workflow already pushes that tag on every main push, so dev rolls
automatically. Prod keeps `:dev` — rolls only on a conscious `git tag
v*`.

**Deploy-verification habit.** After any `docker compose up -d
--force-recreate`, verify the running binary actually contains your
change before assuming the deploy landed:

```
ssh <vps> "cd /opt/ovp && docker compose exec -T <service> sh -c \
  'grep -a -oE \"YOUR_NEW_LOG_STRING\" /usr/local/bin/<binary> | head'"
```

If the new string isn't there, the deploy didn't take. Investigate
before re-testing — don't burn a debugging cycle against stale bits.

**Followup that's still open (task #68).** Also add `:dev` to the
main-push tag list in the workflow so a hotfix to main bypasses the
explicit v-tag step. Would also need prod-compose to move off `:dev`
first, otherwise every main push hits prod. Lower priority now that
dev rolls autonomously via `:branch-main`.

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
