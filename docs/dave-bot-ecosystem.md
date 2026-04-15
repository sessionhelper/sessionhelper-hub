# Discord DAVE Bot Ecosystem

Research snapshot as of 2026-04-09, focused on third-party bots that participate in DAVE-enabled (E2EE) voice calls, with emphasis on recording/receive-path bots. Discord enforces DAVE on non-stage voice channels starting 2026-03-02 (close code 4017 if the client lacks DAVE), so every bot in scope has had to ship DAVE support within a ~6-month window.

## 1. Active DAVE-supporting bots

| Bot | Scope | Language / stack | DAVE status | Known problems | Source |
|---|---|---|---|---|---|
| **Craig** (CraigChat) | Multi-track voice recorder, the de-facto recording bot | Node.js / TypeScript on CraigChat/dysnomia (Eris fork) + `@snazzah/davey` 0.1.8 | Shipping. E2EE recording works. | Ships a reinit-on-N-failures workaround (see below) | https://github.com/CraigChat/craig, https://craig.chat/ |
| **Archivist AI** | TTRPG transcription/summary SaaS, real-time Deepgram | Closed source, Discord bot | Claims to work post-enforcement | Unknown | https://www.myarchivist.ai/ |
| **CharGen** | TTRPG recording + live transcription | Closed source | Claims broadcast-quality post-DAVE | Unknown | https://char-gen.com/discord |
| **The DM's ARK** | TTRPG real-time transcription/notes | Closed source, beta | Claims to work | Unknown | https://thedmsark.com/ |
| **Kazkar** | TTRPG session chronicle + lore wiki | Closed source | Claims to work | Unknown | https://kazkar.ai/blog/best-discord-bots-dnd-2026 |
| **DiscMeet** | AI meeting notes + transcription | Closed source | Claims to work | Unknown | https://discmeet.com/ |
| **GM Assistant** | TTRPG notes automation | Closed source | Unclear if it records in-channel or uses external capture | Unknown | https://gmassistant.app/ |
| **FalconAJC248/TTRPG-Notemate** | Open-source TTRPG capture/transcription pipeline | Python (py-cord + davey), single maintainer | Early, pre-release, no DAVE-specific release notes | Unknown | https://github.com/FalconAJC248/TTRPG-Notemate |
| **automagik-dev/omni** | General voice gateway platform (not TTRPG-specific) | Bun-native, custom Discord Voice Gateway v8 + `@snazzah/davey` | In-progress PR #396 (2026-04) | N/A | https://github.com/automagik-dev/omni/pull/396 |
| **Volpestyle/clanky** | AI companion bot with music ducking | Custom Rust voice subprocess, `davey` crate directly, no songbird | Open-source, merged 2026-03-03. Has "DAVE E2EE full lifecycle — MLS transitions, decrypt recovery, protocol version passthrough" in its PR description | Confirms this class of bug exists | https://github.com/Volpestyle/clanky/pull/15 |
| **frizzle-chan/frizzle-phone** | Discord↔PSTN phone bridge | Python (discord.py + davey) | Shipping — has dedicated DAVE failure issues (#54, #56) | Saw 100% decrypt-failure on real calls; fix was "return None on failure to trigger PLC" (symptomatic, not root cause) | https://github.com/frizzle-chan/frizzle-phone/issues/54 |
| **NousResearch/hermes-agent** | LLM voice agent | Python (discord.py) | Shipping, has DAVE reliability fixes (PR #1418) | Bot-goes-deaf after 60s, missing SSRC handling, DAVE passthrough for unknown SSRCs | https://github.com/NousResearch/hermes-agent/pull/1418 |

Bots that do **not** participate in voice and therefore are unaffected: Sesh, Pancake, Carl-bot (chat/automation only — DAVE is a voice/video protocol).

Dead music bots (Rythm, Groovy) are irrelevant — they were shut down before DAVE existed.

## 2. Library landscape

### Rust

- **Snazzah/davey** — https://github.com/Snazzah/davey — 64 stars, Discord DAVE in Rust on top of OpenMLS. Also produces `davey-node` (npm `@snazzah/davey`) and `davey-python` (`davey`). This is the only non-libdave implementation. Current crate version `0.1.3` (2026-03-29), updated to newer openmls via PR #14. **Snazzah maintains both davey and Craig**, so the bot and the library are co-evolving.
- **serenity-rs/songbird** — https://github.com/serenity-rs/songbird — DAVE landed in PR #291 (merged 2026-03-28, closed #293 "E2EE/DAVE protocol required"). Uses `davey` via OpenMLS. Author `beer-psi` notes in the PR: "if your bot needs this it's been tested and working on a few bots" and calls out several rough edges (SpeakingStateUpdate inconsistency, early-packet drops). `serenity-next` users depend on `jtscuba/songbird@davey` fork. This is the branch we are on.

### Node.js

- **@snazzah/davey** — the only maintained DAVE library for Node/JS. Used by `@discordjs/voice` (pre-installed since 0.19.0, discord.js PR #10921 merged 2025-07-13), Craig's Eris fork (CraigChat/dysnomia PR #196), and everything else.
- **CraigChat/dysnomia** — Craig's private Eris fork. Relevant history:
  - PR #196 (2025-09-12): initial DAVE support
  - PR #228 (2025-11-08): **"Add DAVE decryption failure tolerance"** — `DEFAULT_DECRYPTION_FAILURE_TOLERANCE = 36`, `recoverFromInvalidTransition()` made public, new `lastTransitionID` and `reinitializing` properties. Explicitly mirrors discord.js #10921's approach.
  - PR #229–230 (2025-11-10/17): padding-packet handling, drop empty-padding packets that fail DAVE decryption on Cloudflare voice servers.
- **discord.js / @discordjs/voice** — Ships DAVE but has visible receive-path bugs (see §3). 0.19.x entered general use Feb 2026.

### Python

- **DisnakeDev/dave.py** — https://github.com/DisnakeDev/dave.py — Python bindings *over `discord/libdave`* (C++, not via davey). Low visibility (3 stars).
- **davey-python** (from Snazzah/davey) — pypi `davey`. Used by py-cord and the majority of hobbyist Python bots. Known segfault on aarch64/Raspberry Pi 5 Python 3.13 (davey #13), and the 95% decrypt-failure report (davey #15).
- **py-cord** — Pycord-Development/pycord PR #3143 (merged 2026-03-08) rewrote voice internals + DAVE send support; PR #3159 (still open, 2026-03-19) adds DAVE voice **receive** ("recv"). Receive fixes went through PR #3168, #3179, #3185 — all closed within a week. The fix in #3179 is literally "fall back to OPUS_SILENCE when DAVE brute-force uid lookup fails", which is a symptom of the per-user decryptor being missing or desynced. They also landed #3168 "correct ssrc↔user_id cache direction in DAVE decrypt fallback".
- **discord.py (Rapptz)** — Gatekeeper stance: PR #10375 (closed Jan 2026) added binary-WS plumbing so *third parties* can implement DAVE, but Rapptz has not accepted a full DAVE implementation in-tree (PR #10300 closed). Issue #9948 remains as the feature request. Consequence: vanilla discord.py bots drop calls out of E2EE.
- **disnake** — DisnakeDev PR #1492 (merged 2026-01-03) `feat(voice): add DAVE protocol (E2EE) support`; PR #1512 added 4017 close code; PR #1513 handles additional WS close codes. disnake uses `dave.py` (libdave bindings), **not** davey — so they have a different failure mode profile than Craig, py-cord, songbird, discord.js.

### Java

- **MinnDevelopment/jdave** — https://github.com/MinnDevelopment/jdave — 24 stars, active. Wraps `discord/libdave` via JNI. Current 0.1.8 (2026-03-29). **Has had the exact multi-user bug we're chasing**: JDA issue #2998 "JDA + JDave breaks with more than two users in the voice channel" was fixed in jdave `0.1.0-rc.3` (2026-01-10) by MinnDevelopment. The symptom was word-for-word the same — decrypt failures spam once a second user joins, clears only when everyone leaves and one joiner remains. The fix lived in JDave PR/commit "Transition encryptor to passthrough if no key ratchet is null" and "Fix protocol transitions on existing dave sessions" (jdave #14). This confirms the bug class is *libdave-downstream* as well, not purely a Rust-OpenMLS artifact.
- **discord-jda/JDA** — Downstream of jdave. Still accumulating DAVE-related receive issues (#2996, #3000, #3034 "Why isn't anyone talking about how discord vc is completely broken?", #2988).

### C++ / C#

- **discord/libdave** — https://github.com/discord/libdave — 246 stars. Discord's own C++ implementation used by the Discord client. Distributed pre-built since issue #8. Memory-safety notes from the Trail of Bits audit; Discord acknowledged they picked C++ for "external requirements" and expect to move off it eventually.
- **NetCordDev/libdavec** — C wrapper over libdave (7 stars).
- **kordlib/dave.kt** — Kotlin bindings for Kotlin Discord library Kord.
- **n1d3v/DiscordDAVECalling** — C# P/Invoke libdave prototype (1 star, mostly a toy).
- **No dedicated C# Discord.NET/NetCord DAVE library at a bot-ready level yet** — they all route through libdavec.

### Short answer on "who has the bug, who has the fix"

| Library | Multi-user proposal race | Fix shipped? |
|---|---|---|
| davey (Rust/Node/Python) | Reported implicitly (davey #15, pycord #3179, frizzle-phone #54, hermes-agent #1418, clanky PR #15, our repro) | **Not explicitly.** Each consumer has its own reinit-on-N-failures workaround. |
| jdave (Java + libdave) | Reported (JDA #2998) | **Yes**, jdave 0.1.0-rc.3 (2026-01-10). Fix touched "transition encryptor to passthrough when key ratchet is null" + "fix protocol transitions on existing dave sessions". |
| libdave (C++ upstream) | Partially mitigated by jdave's fix above — the transition handling was on the jdave side, but the key-ratchet-null scenario is a libdave edge case. No direct libdave issue filed. |
| @discordjs/voice | #11419 (reconnect loops), #11441 (34% silent packet loss during MLS key transitions), #11445 (UnencryptedWhenPassthroughDisabled on all frames) — all closed by adding the 36-failure tolerance + recover-reinit workaround. |
| py-cord | #3168, #3179, #3185 — same class, same symptomatic fixes. |

Two reproducible observations from this table:

1. **Everyone has variants of the same bug.** The symptoms cluster into: (a) decrypt fails after N-th user joins within the transition window, (b) ~30% silent packet loss across epoch boundaries, (c) "NoDecryptorForUser" or `UnencryptedWhenPassthroughDisabled` errors on the decrypt path, (d) unknown-SSRC paths that never get a key ratchet.
2. **Nobody has fixed the root cause in davey.** jdave fixed their bug by ensuring passthrough when key ratchet is null and by correcting "protocol transitions on existing dave sessions". Craig's dysnomia fork, discord.js, and py-cord all ship *detect-and-reinit tolerance counters* rather than fixing the underlying OpenMLS proposal clearing. Our workaround (detect-and-reconnect heal triggered by OP5) is the same class of fix, just with different triggers.

## 3. Known issues across the ecosystem

Consolidated from GitHub search (2025-12 through 2026-04):

**Multi-user decryption failures (the class we hit)**
- https://github.com/discord-jda/JDA/issues/2998 — "JDA + JDave breaks with more than two users in the voice channel" — fixed in jdave 0.1.0-rc.3
- https://github.com/Snazzah/davey/issues/15 — "Most DAVE-encrypted audio packets fail to decrypt (~95% failure rate)" — open, pycord user, referenced discord.js #11419
- https://github.com/Pycord-Development/pycord/issues/3179 — OPUS_SILENCE fallback when brute-force uid lookup fails
- https://github.com/Pycord-Development/pycord/issues/3168 — ssrc↔user_id cache direction wrong in DAVE decrypt fallback
- https://github.com/MinnDevelopment/jdave/issues/32 — "Decrypt failed with error code FAILURE" — still open, jdave 0.1.7
- https://github.com/frizzle-chan/frizzle-phone/issues/54 — 100% DAVE decrypt failure on phone bridge
- https://github.com/discordjs/discord.js/issues/11419 — reconnect loops + zero audio capture

**Silent packet loss at epoch boundaries**
- https://github.com/discordjs/discord.js/issues/11441 — 34% silent drop during MLS key transitions. Exactly the "packets vanish during the ~10-second transition window" symptom we see.

**Reconnect loops**
- https://github.com/discordjs/discord.js/issues/11384 — protocol version check when `getMaxProtocolVersion()` returns undefined
- https://github.com/discordjs/discord.js/issues/11387 — unhandled back-pressure in DAVE encryption
- https://github.com/discordjs/discord.js/issues/11419 — reconnect loops
- https://github.com/MinnDevelopment/jdave/issues/23 — SIGSEGV triggering full JVM crash (fixed)

**libdave/jdave memory/crash issues**
- https://github.com/MinnDevelopment/jdave/issues/23 — fatal errors triggering full crash
- https://github.com/MinnDevelopment/jdave/issues/26 — segfault when using jemalloc/tcmalloc
- https://github.com/discord/libdave/issues/7 — MinGW compile break
- https://github.com/Snazzah/davey/issues/13 — SEGV on aarch64 / Raspberry Pi 5 / Python 3.13

**Audio quality degradation**
- Indirect: multiple bots have added silent-keepalive every 15s (hermes-agent #1418) because UDP routes drop after 60s of silence in DAVE mode, which seems related to the encrypted media layer changing packet pacing.

**Trail of Bits audit findings relevant to bots**
- TOB-DISCE2EC-5 (low severity, high difficulty): during transition phases a sophisticated participant can present different ciphertexts to different parties. Not a bot bug, but it means bots that record during transitions *could* see a different ciphertext stream than human participants — worth being aware of if we ever need to attest to recording fidelity.
- Audit also flagged C++ memory safety and recommended Discord move off C++ "eventually". That's material because the non-C++ stacks (davey/Rust, pycord pure Python) *should* be on safer ground — but they're the ones still shipping MLS proposal race workarounds, so library maturity is the bigger risk right now than memory unsafety.

## 4. Where we stand

**We are not ahead or behind — we are in the same boat as every other davey-based bot and we have a cleaner failure model than most.**

Concrete comparisons:

- **Craig** ships the canonical workaround: a decryption-failure tolerance counter (36 consecutive failures → `recoverFromInvalidTransition`, which tears the DAVE session down and rebuilds it). This is exactly our "detect-and-reconnect heal" strategy, just in TypeScript. Craig's advantage is Snazzah maintaining both sides of the davey/bot interface, so his fixes land faster.
- **discord.js 0.19.x** ships the same tolerance counter (PR #10921) and still has #11441 "34% silent packet loss" open as a symptom the counter doesn't fully address.
- **py-cord** ships brute-force uid lookup + OPUS_SILENCE fallback, which is a weaker version of the heal — it masks the symptom for a single packet, not a whole session.
- **jdave** is the only stack that has a root-cause fix, and it's upstream of libdave rather than in OpenMLS. Their fix ("transition encryptor to passthrough if no key ratchet is null", jdave commit 29134d3) suggests the real issue is *which proposals are pending when the MLS commit lands for a given joiner*, not memory corruption.
- **Clanky** (Volpestyle) is the closest architectural analog to us: custom Rust voice subprocess, davey crate directly, DAVE lifecycle code including "decrypt recovery, protocol version passthrough". They landed DAVE E2EE full lifecycle on 2026-03-03 — less than a month ago — and their PR body explicitly lists "MLS transitions, decrypt recovery, protocol version passthrough" as features, which is code for "we ran into the same bug and papered over it".

**What makes our position unusual:**

1. **We've identified the mechanism inside davey** (MLS proposal clearing race → only the last joiner's decryptor survives). No other public issue tracker has articulated this precisely. davey #15 and JDA #2998 describe the *symptom*. The jdave commit comments describe the *fix in jdave-land* without naming the root cause. We appear to be the first to pinpoint it in davey's Rust code.
2. **We have a targeted trigger** (OP5 detection to force heal), not just a blind failure counter. That's more efficient than the 36-packet tolerance because it catches the problem before any packets are lost, though it leans on Discord's OP5 gateway signal being reliable.
3. **We're on songbird `next`** — which has had DAVE for less than two weeks (merged 2026-03-28). We're exercising PR #291 code that has one merged author (`beer-psi`) and no production user base, so we're doing the QA for the branch.

**What we're missing vs. the field:**

- Craig has a much larger deployment footprint and the author can push davey changes directly. We should assume whatever bug we have, they either (a) already worked around it, (b) will work around it in the next davey/dysnomia release, or (c) can tell us in one message.
- pycord's PR #3159 (still open) contains receive-path fixes that might share root causes with our issue. Worth reading the diff.
- jdave's actual fix commit is visible on GitHub and is a good place to look for ideas on what "passthrough when ratchet is null" means in the davey context.

## 5. Potential collaborators

Ranked by likelihood of being useful:

1. **Snazzah** (snazzah@snazzah.com) — maintains davey, dysnomia, and Craig. Single most leveraged contact; owns the library we're blocked on. Discord username active in Discord Developers server. Any reproducible davey bug with a minimal Rust test case is more likely to land in his tree than anything else we could do.
2. **beer-psi** — author of songbird PR #291 (DAVE support). The only person who has shipped davey in a Rust voice library. Was active 2026-02 through 2026-03-28. GitHub handle `beer-psi`.
3. **MinnDevelopment** — maintains jdave and JDA, already fixed a sibling version of our bug. Worth asking "what exactly did 'transition encryptor to passthrough if no key ratchet is null' mean in libdave terms?" — the answer likely translates directly to davey's proposal handler.
4. **jtscuba** — maintains the serenity-next fork of songbird's DAVE branch (`jtscuba/songbird@davey`). Parallel track to upstream, might already have patches we need.
5. **Volpestyle/clanky maintainers** — they shipped a custom Rust voice subprocess with davey just weeks ago and hit the "decrypt recovery" problem. Same shape of codebase as ours. PR #15 contributors are the obvious ask.
6. **automagik-dev/omni** (PR #396 author) — building an open voice gateway on Bun + davey. Not Rust, but they're building voice *infra*, not a one-shot bot, so they care about the same reliability properties.
7. **frizzle-phone, hermes-agent, FalconAJC248/TTRPG-Notemate** — fellow hobbyists with public DAVE bug reports. Useful for cross-confirming symptoms but probably not fix contributors.
8. **pycord core team** — PR #3159 is the natural place to post "here's what we observed in davey proposals" if we want the wider Python community to benefit.

Not worth approaching right now: Rapptz/discord.py (gatekeeper stance, PR #10300 closed), commercial TTRPG bots (all closed source, no incentive to share).

## 6. Key links and sources

### Official Discord
- [DAVE protocol whitepaper](https://daveprotocol.com/)
- [discord/dave-protocol](https://github.com/discord/dave-protocol)
- [discord/libdave](https://github.com/discord/libdave)
- [Meet DAVE blog post](https://discord.com/blog/meet-dave-e2ee-for-audio-video)
- [Bringing DAVE to All Discord Platforms](https://discord.com/blog/bringing-dave-to-all-discord-platforms)
- [A/V E2EE Enforcement for Non-Stage Voice Calls](https://support.discord.com/hc/en-us/articles/38749827197591-A-V-E2EE-Enforcement-for-Non-Stage-Voice-Calls)
- [Minimum Client Version Requirements for Voice Chat](https://support.discord.com/hc/en-us/articles/38025123604631)

### Libraries
- [Snazzah/davey](https://github.com/Snazzah/davey)
- [Snazzah/davey issue #15 — 95% decrypt failure](https://github.com/Snazzah/davey/issues/15)
- [Snazzah/davey issue #13 — aarch64 SEGV](https://github.com/Snazzah/davey/issues/13)
- [serenity-rs/songbird](https://github.com/serenity-rs/songbird)
- [Songbird PR #291 — DAVE support](https://github.com/serenity-rs/songbird/issues/291)
- [Songbird issue #293 — E2EE/DAVE protocol required](https://github.com/serenity-rs/songbird/issues/293)
- [discordjs/discord.js PR #10921 — DAVE implementation](https://github.com/discordjs/discord.js/pull/10921)
- [discordjs/discord.js issue #11419 — reconnect loops](https://github.com/discordjs/discord.js/issues/11419)
- [discordjs/discord.js issue #11441 — 34% silent packet loss](https://github.com/discordjs/discord.js/issues/11441)
- [discordjs/discord.js issue #11445 — UnencryptedWhenPassthroughDisabled](https://github.com/discordjs/discord.js/issues/11445)
- [CraigChat/dysnomia PR #196 — DAVE](https://github.com/CraigChat/dysnomia/pull/196)
- [CraigChat/dysnomia PR #228 — DAVE decryption failure tolerance](https://github.com/CraigChat/dysnomia/pull/228)
- [MinnDevelopment/jdave](https://github.com/MinnDevelopment/jdave)
- [discord-jda/JDA issue #2998 — breaks with more than two users](https://github.com/discord-jda/JDA/issues/2998)
- [DisnakeDev/dave.py](https://github.com/DisnakeDev/dave.py)
- [DisnakeDev/disnake PR #1492 — DAVE protocol support](https://github.com/DisnakeDev/disnake/pull/1492)
- [Pycord-Development/pycord PR #3159 — DAVE receive](https://github.com/Pycord-Development/pycord/pull/3159)
- [Pycord-Development/pycord PR #3179 — OPUS_SILENCE fallback](https://github.com/Pycord-Development/pycord/pull/3179)
- [Rapptz/discord.py issue #9948 — DAVE feature request](https://github.com/Rapptz/discord.py/issues/9948)
- [Rapptz/discord.py PR #10375 — binary WebSocket support for DAVE](https://github.com/Rapptz/discord.py/pull/10375)

### Bots
- [CraigChat/craig](https://github.com/CraigChat/craig)
- [craig.chat](https://craig.chat/)
- [automagik-dev/omni PR #396 — Bun voice gateway](https://github.com/automagik-dev/omni/pull/396)
- [Volpestyle/clanky PR #15 — custom Rust voice pipeline with DAVE E2EE](https://github.com/Volpestyle/clanky/pull/15)
- [frizzle-chan/frizzle-phone issue #54 — DAVE decrypt fails on all audio](https://github.com/frizzle-chan/frizzle-phone/issues/54)
- [NousResearch/hermes-agent PR #1418 — Discord voice reliability fixes](https://github.com/NousResearch/hermes-agent/pull/1418)
- [FalconAJC248/TTRPG-Notemate](https://github.com/FalconAJC248/TTRPG-Notemate)

### Commercial TTRPG bots
- [Archivist AI](https://www.myarchivist.ai/)
- [CharGen](https://char-gen.com/discord)
- [The DM's ARK](https://thedmsark.com/)
- [Kazkar](https://kazkar.ai/)
- [DiscMeet](https://discmeet.com/)
- [GM Assistant](https://gmassistant.app/)

### Background reading
- [IETF MLS architecture draft](https://datatracker.ietf.org/doc/html/draft-ietf-mls-architecture-15)
- [Discord rolls out MLS encryption — The Stack](https://www.thestack.technology/discord-encryption-mls-e2ee/)
- [BleepingComputer: Discord rolls out end-to-end encryption](https://www.bleepingcomputer.com/news/security/discord-rolls-out-end-to-end-encryption-for-audio-video-calls/)
- [The Hacker News: Discord DAVE protocol](https://thehackernews.com/2024/09/discord-introduces-dave-protocol-for.html)
