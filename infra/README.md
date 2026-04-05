# Infrastructure — hosting and ops journey

Abstract notes on the infrastructure decisions for a small, minimalist, voice-capturing Discord bot + HTTP storage API. No specific IPs, SSH users, credential paths, or account details are in this repo — those live in a local-only private companion on the maintainer's machine. This doc is for someone traveling the same path who wants to know the *shape* of the choices, not their values.

## Hosting provider

We picked **Hetzner Cloud** over the usual suspects (AWS, GCP, DigitalOcean, Linode, Fly). The math:

| Provider | Cheapest usable VPS | Bandwidth | Notes |
|---|---|---|---|
| **Hetzner Cloud** | **~€4/mo** (CPX11: 2 vCPU, 2 GB RAM, 40 GB SSD) | 20 TB/mo | Strong EU presence, US regions since 2023, IPv6 free |
| DigitalOcean | ~$6/mo (1 vCPU, 1 GB RAM) | 500 GB | More mindshare, more expensive, less generous bandwidth |
| AWS (t4g.nano + EBS) | ~$4/mo on paper, ~$10/mo in practice | Metered, trap-door pricing | Only worth it if you're already there |
| Fly.io | ~$5/mo small VM | Metered egress | Great DX, tight free tier, surprises on multi-region |

Hetzner's CPX11 class covers a Rust Discord bot + a containerized Postgres + a storage-abstraction HTTP service comfortably, with room for the pipeline worker when it lands. **Cost is 5-10× lower than the equivalent AWS setup**, and bandwidth is the best in class for the tier. The tradeoff is fewer managed services — you bring your own Postgres, your own monitoring, your own everything — which is fine when the whole stack is four containers.

## Separate dev and prod VPS

Two VPS instances, not one. Reasons:

- **Refactor safety.** The entire bot has been rewritten mid-flight more than once. A dev VPS means "blow away and rebuild" never touches the bot your real users (if any) are using.
- **Independent Discord applications.** Each VPS runs its own Discord bot token against its own Discord developer app. Mixing tokens is how you accidentally post test messages to a production guild.
- **Different data buckets.** Dev points at one S3 bucket, prod at another. No cross-contamination.
- **~€8/mo total** (one CPX21 dev + one CPX11 prod). Worth it for the blast-radius isolation.

For a one-person project, you don't need a staging environment on top of dev. "Dev with the real prod bot token mounted for manual testing" is the staging environment when you need it.

## Object storage

Hetzner also runs **Object Storage** (S3-compatible) at ~€0.50–€1/mo for typical volumes. Same provider as the VPS = same billing, same control panel, no cross-cloud egress. We use two buckets:

- One for **prod** audio captures
- One for **dev** scratch data (freely deletable)

Access goes through a single S3 access key pair stored in `pass`. Keys are passed into the data-api service via env vars at container start — never hardcoded anywhere.

## Service architecture

Four components, all on the same host:

```
 ┌──────────────────────────────────────────────┐
 │              Docker compose network          │
 │                                              │
 │   postgres:16      data-api      collector   │
 │   (internal)   (127.0.0.1:8001)  (no port)   │
 │                                              │
 └──────────────────────────────────────────────┘
                         │
                         │  external only to Discord
                         ▼
                    Discord gateway
                  (voice + slash commands)
```

Everything talks over Docker's internal DNS. Only the data-api listens on a host port (loopback only) so you can `ssh -L` into it for debugging. The collector bot never exposes a port.

### Why this shape

- **One Postgres per stack.** Containerized, data in a named volume. No shared DB across services. If you want the data out, pg_dump.
- **The data-api is the only thing that touches storage.** Postgres + S3. Every other service is an HTTP client. This makes schema migrations and S3 auth rotations single-point changes, and makes the collector and worker stateless.
- **Shared-secret service auth.** See [`CLAUDE.md`](../CLAUDE.md#shared-secret-service-auth). Every service in the deployment reads the same `SHARED_SECRET` env var, exchanges it for a session token, and heartbeats. No rotation until you have a security incident. No file-based tokens. No Vault.
- **Systemd unit wraps `docker compose up -d`.** Survives reboots, gives you `systemctl restart ovp-data-api` as the one deploy operation, logs to journalctl.

## Secrets management

- **`pass`** (the standard Unix password manager, GPG-backed) on the maintainer's machine is the source of truth for every credential.
- **`.env` files chmod 600** on each VPS hold the runtime values, generated fresh from `pass` on each deploy. Never committed to any repo.
- **Shared secret per deployment**, not per service. Makes auth debugging trivial: if two services disagree about a token, exactly one place to look.
- **GHCR pull tokens** live on the VPS as personal access tokens with `read:packages` only. Rotate yearly.

## CI/CD

Both services have identical GitHub Actions shape:

```
on: push (branch=dev or PR)  →  cargo check + clippy + test
on: push (tag v*)            →  docker build + ghcr push + ssh deploy
```

The deploy step is a single SSH command that `docker compose pull`s the updated image and restarts the systemd unit. Total pipeline time from `git push origin v1.2.3` to the new bot being live: ~5 minutes.

Image tags on GHCR: `:latest`, `:dev`, `:v1.2.3`. The compose file references `:dev` so automatic rollouts happen on tag push. Specific version tags let you roll back by editing the compose file.

## Monitoring and observability

Deliberately minimal for this stage of the project:

- **Structured logs** via `tracing` on the Rust side. Spans with meaningful field names, not printf. `journalctl -u ovp-data-api` gets you the full picture on the VPS.
- **Metrics via the `metrics` crate facade.** A Prometheus exporter feature is compiled in but not enabled in dev; turn it on when you actually need graphs.
- **No APM, no Sentry, no log shipping.** If the VPS melts, you SSH in and read the journal. At this scale that's the right tool.

When the project has real users: add an external uptime monitor (Uptime Kuma on the dev VPS is free), then a log shipper to something like Grafana Cloud's free tier.

## What lives where

| Concern | Location |
|---|---|
| Specific VPS IPs, SSH users, systemd unit details, exact pass entry names | Private companion repo (local-only) |
| Compose file skeleton (this repo) | `dev-compose.yml` |
| Abstract "why we chose X" — this document | This repo, published |
| Credential storage | `pass` on the maintainer's machine |
