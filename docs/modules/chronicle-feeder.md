# chronicle-feeder

Dev-only Discord bot fleet used for end-to-end testing of `chronicle-bot`. Typically run as a squad of 4 instances (moe, larry, curly, gygax) controlled by external test scripts. Not deployed in production; containerized alongside the dev stack only.

Feeders **simulate players** for E2E tests. Each feeder has a Discord user_id that test scripts treat as a first-class test primitive, driving it through the same session lifecycle a human player experiences — enrol, consent, play audio — via `chronicle-bot`'s harness endpoints. The feeder itself is intentionally dumb about session semantics.

Status: **Features locked. Interfaces and Behavior pending.** Implementation at `/home/alex/sessionhelper/chronicle-feeder/`.

---

## Features

1. **Voice channel join/leave on demand.** External HTTP control causes the feeder to join a specified guild + channel, or leave it. While joined, the feeder appears as a bot user in the voice channel, visible to `chronicle-bot`.

2. **Audio playback on command; silent when not playing.** On `POST /play`, the feeder reads its configured OGG Opus file and streams it to the voice channel. When stopped or idle, the feeder transmits no voice frames. Test scripts are responsible for sequencing: start feeders playing before expecting `chronicle-bot`'s stabilization gate to open.

3. **Feeders simulate players.** A feeder's Discord user_id is a first-class test primitive. Test scripts drive each feeder through the same lifecycle a human player would: join voice → be enrolled as a participant (via `chronicle-bot` harness `POST /enrol`) → record consent (harness `POST /consent`) → play audio. The feeder itself is intentionally dumb about session semantics; the harness endpoints on `chronicle-bot` are the puppet strings. This means E2E tests exercise the same consent + participant code paths that real users do.

4. **Pre-encoded OGG Opus input.** Audio files are expected as OGG Opus (48 kHz stereo, 20 ms frames, CBR), pre-encoded by `scripts/encode-opus.sh`. The feeder reads and feeds them to songbird. No runtime transcoding; the bytes on the wire are exactly what the script produced.

5. **Loopback-only HTTP control surface.** Small axum server bound to `127.0.0.1:<CONTROL_PORT>`. Endpoints: `GET /health`, `POST /join`, `POST /play`, `POST /stop`, `POST /leave`. Not routable from outside the dev host; in the Docker compose file, the container port is mapped to `127.0.0.1:<port>:<port>`.

6. **One feeder per process, one audio file.** The fleet shape (N feeders, N different voices) is achieved by running N containers, each with its own `DISCORD_TOKEN`, `FEEDER_NAME`, `AUDIO_FILE`, and `CONTROL_PORT`. The feeder itself is single-purpose.

7. **Observability.** Tracing logs per control command + per songbird lifecycle event (connect, disconnect, playback start/end). No metrics — this is a test tool, not a production service to monitor.

---

## Interfaces

### Inbound — Discord gateway (via serenity)

- Voice state changes (consumed by songbird internally)
- Ready event (bot user_id logged on startup)

### Inbound — loopback HTTP control

- `GET /health` → `{ name, user_id, in_voice: bool, playing: bool }`
- `POST /join { guild_id, channel_id }` → 200 / 4xx
- `POST /play` → 200 / 409 `{ error: "already playing" }` / 400 if not joined
- `POST /stop` → 200 (noop if not playing)
- `POST /leave` → 200 (noop if not joined)

### Outbound — Discord API (via serenity + songbird)

- Gateway connect + identify
- Voice connect / disconnect
- Voice frame transmission during `/play` via songbird's OPUS passthrough — no runtime transcoding

### Environment variables

| Var | Required | Default | Meaning |
|---|---|---|---|
| `DISCORD_TOKEN` | yes | — | Bot token |
| `FEEDER_NAME` | no | `feeder` | Short identifier for logs |
| `AUDIO_FILE` | yes | — | Path to OGG Opus file to play |
| `CONTROL_PORT` | no | `8003` | Control HTTP port |
| `CONTROL_BIND` | no | `127.0.0.1` | Bind address (compose overrides to `0.0.0.0` with port-mapping host safety) |
| `RUST_LOG` | no | `info,serenity=warn,songbird=warn` | tracing filter |

### Observability

- Tracing spans: per control call (`control{endpoint}`), per songbird lifecycle (`voice{phase}`).
- No metrics.

---

## Behavior

### State machine

```
idle
  │  POST /join
  ▼
joined (voice connected, not transmitting)
  │  POST /play
  ▼
playing (voice frames streaming from AUDIO_FILE)
  │  POST /stop    (or audio file EOF)
  ▼
joined
  │  POST /leave
  ▼
idle
```

Valid transitions:
- `idle → joined` via `/join`
- `joined → playing` via `/play`
- `playing → joined` via `/stop` or natural EOF on the audio file
- `joined → idle` via `/leave`
- `playing → idle` via `/leave` (implicit stop)

Invalid transitions return 4xx:
- `idle` + `/play` → 400 (not in voice)
- `joined` + `/play` while current playback is still active is prevented by state check; returns 409 if caller spams `/play`
- `joined` + `/join` → 409 (already joined; must `/leave` first)

### Invariants

1. **At most one voice connection at a time.** `/join` while already joined returns 409.
2. **At most one active playback at a time.** `/play` while playing returns 409 `{ error: "already playing" }`; caller must `/stop` first.
3. **Loopback control by default.** Control HTTP listens on 127.0.0.1 unless `CONTROL_BIND` is explicitly set. In compose, the 0.0.0.0 bind is gated by the host's port mapping to `127.0.0.1:<port>`.
4. **No runtime transcoding.** OPUS frames from the AUDIO_FILE are forwarded to songbird's passthrough path untouched. If songbird declines the passthrough (unsupported frame parameters), the feeder logs an error and falls back to songbird's decode → re-encode path; it does not silently degrade.

### Error handling

- **Discord connection lost:** songbird auto-reconnects. Feeder stays `joined` from the state-machine POV; subsequent `/play` calls wait for reconnect before transmitting.
- **Audio file missing at `/play` time:** 404 with `{ error: "audio file missing: <path>" }`. Feeder remains `joined`.
- **Songbird call handle gone between `/join` and `/play`:** transition back to `idle`; return 400 on `/play`.
- **Panic in control handler:** axum error middleware returns 500; process stays up.

### Scope fence

The feeder does **not**:

- Implement any session logic — consent, license, participant enrolment. Those are `chronicle-bot`'s harness responsibility.
- Record audio inbound from the voice channel. It is an output-only actor.
- Participate in Discord slash commands or interactions. Only HTTP control.
- Transcode audio. `AUDIO_FILE` must be pre-encoded by `scripts/encode-opus.sh`.
- Run in production. Dev-only.

Additions require explicit Features entry with Interfaces + Behavior implications.
