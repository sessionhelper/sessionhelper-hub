# Voice Capture Requirements

Requirements for reliable multi-speaker audio capture through Discord
voice channels. These are non-negotiable for the product to work.

## R1: All consented speakers must be captured

Every participant who clicks Accept must have their per-speaker audio
captured and uploaded. Zero tolerance for silent/missing tracks. A
session with 4 consented speakers must produce 4 audio tracks.

## R2: DAVE health detection is event-driven, not content-based

The system detects broken DAVE decryption using a single signal:
**SpeakingStateUpdate (OP5) fires but the speaker's SSRC never
appears in VoiceTick.** No amplitude analysis, no voice_state
cross-reference, no per-speaker packet counting.

Detection logic:

```
OP5 fires for user X → start 2-second timer
  → SSRC appears in VoiceTick before timer expires → DAVE is working
  → timer expires with no SSRC → DAVE is broken → trigger heal (R3)
```

Why this works:

- **DAVE working:** OP5 fires → RTP decrypted → SSRC in VoiceTick
  within milliseconds. Timer cancelled.
- **DAVE broken:** OP5 fires (voice server sees RTP from client) →
  RTP dropped at decryption stage → SSRC never appears → timer
  expires → heal.
- **Player muted (self_mute):** No RTP sent → no OP5 fires → no
  timer started → no false positive.
- **Player PTT not pressed:** No RTP sent → no OP5 fires → correct.
- **Hardware mute:** Client sends silence frames → OP5 fires → SSRC
  appears (silence is still decoded audio) → healthy.

Why NOT audio content:

- Players use push-to-talk, mute their mics, or stay silent for
  extended periods. Amplitude thresholds cannot distinguish "player
  hasn't spoken yet" from "DAVE decryption is broken."
- OP5 is the voice server telling us "this user IS transmitting."
  If we can't hear them after that, decryption is broken.

## R3: Self-healing on DAVE failure

If R2's check detects a broken speaker, the collector must
automatically recover by leaving and rejoining voice to get a fresh
MLS Welcome. This must happen within 15 seconds of recording start.
The "recording started" announcement replays on successful heal.

The heal runs once. If it fails, log the failure and continue
recording the speakers that work. Do not loop.

## R4: MLS group must be stable before collector joins

The collector joins voice AFTER all participants are in the channel.
In production, this is natural (/record fires after participants are
present). In the E2E harness, a 10-second stabilization delay between
participant joins and collector join is required.

## R5: Chunk size is 2MB (~10 seconds of voice)

Audio is uploaded in 2MB chunks (48kHz stereo s16le = ~10.9 seconds
per chunk). This balances real-time latency against VAD sentence
boundary detection.

## R6: No false heals on muted/PTT users

The DAVE heal (R3) must never trigger for a user who simply isn't
transmitting. The OP5-triggered model (R2) provides this guarantee
structurally:

- **Muted users** don't send RTP → Discord's voice server doesn't
  fire OP5 → no heal timer starts → no false positive.
- **PTT-not-pressed** same as muted — no RTP, no OP5.
- **Hardware mute** sends silence frames → OP5 fires → SSRC appears
  in VoiceTick (silence is decoded audio) → healthy.

No voice_state cross-reference is needed. Discord's voice server
already performs the classification by only firing OP5 when it
actually receives RTP packets from the client.

### E2E test scenarios

- **4 speakers, all transmitting:** OP5 fires for all 4 → SSRCs
  appear → no heal triggered → all 4 captured
- **4 speakers, 1 muted:** OP5 fires for 3 only → no heal for the
  muted speaker → 3 captured, muted speaker correctly ignored
- **4 speakers, DAVE broken for 2:** OP5 fires for all 4 → 2 SSRCs
  never appear → heal triggers → reconnect recovers the 2
- **Speaker unmutes mid-session:** OP5 fires on first transmission
  → SSRC appears → audio capture begins naturally

## R7: No data loss on transient failures

S3 upload failures must be retried (3 attempts, 1s backoff). Chunk
sequence must be preserved. If the data-api is temporarily unreachable,
chunks are buffered locally and uploaded when connectivity resumes.

## Root cause reference: DAVE/MLS multi-join race

When multiple participants join a voice channel within ~3 seconds,
songbird's MLS proposal handling races: each new Add proposal clears
the pending commit from the previous join, causing that participant's
key material to be lost. Only the last joiner's decryptor survives.

This is a bug in songbird's `ws.rs` → `process_proposals()` which
clears pending commits instead of queuing proposals. The fix belongs
upstream. Our R3 (self-healing reconnect) is the application-level
mitigation.

See: `/home/alex/.cargo/git/checkouts/songbird-f35e179d3fad55dd/2188c09/src/driver/tasks/ws.rs`
and: `/home/alex/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/davey-0.1.3/src/session.rs`
line 496-501 (`process_proposals` clearing pending commits).
