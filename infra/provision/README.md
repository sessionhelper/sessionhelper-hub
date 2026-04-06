# SSH-based Infrastructure Provisioning

Provisions cloud servers on demand via provider APIs, configures them over SSH, and tears them down when done. No Terraform, no proprietary snapshots -- just SSH, shell scripts, and API calls.

## Quick start

```bash
# Ensure the Hetzner API token is available
pass insert sessionhelper/hetzner-api-token   # one-time
# OR
export HETZNER_API_TOKEN=hc_...

# Upload your SSH key to Hetzner (one-time)
./provision.sh upload-ssh-key

# Dry run to see what would happen
./provision.sh up worker --dry-run

# Provision a worker server
./provision.sh up worker

# List active servers
./provision.sh list

# SSH into a server
./provision.sh ssh <server-id>

# Health check
./provision.sh status <server-id>

# Tear down
./provision.sh down <server-id>
```

## Profiles

| Profile | Server type | Purpose |
|---|---|---|
| `worker` | cpx21 (Hetzner) | ovp-worker + data pipeline, CPU only |
| `gpu-inference` | ccx33 (Hetzner) | Ollama + qwen2.5:7b (CPU fallback) |
| `whisper` | ccx33 (Hetzner) | faster-whisper-server |
| `dev-stack` | cpx31 (Hetzner) | Full compose: postgres + data-api + collector + worker |

Profiles are env files in `profiles/`. They do not contain secrets.

## Cache

Run `./cache-build.sh` before provisioning to save Docker images and models locally. These get rsynced to the server, avoiding slow pulls over the network.

## Architecture

```
provision.sh  (entry point)
  |
  +-- profiles/*.env       (what to create)
  +-- providers/hetzner.sh (how to talk to the cloud API)
  +-- setup/*.sh           (what to run on the server)
  +-- cache/               (artifacts to push via rsync)
  +-- state/servers.json   (local tracking of active servers)
```

All state is local. Servers are named `sh-<profile>-<hex4>`. Each `up` creates a new server (no implicit singletons).

## Prerequisites

- `curl`, `jq`, `rsync`, `ssh` on the local machine
- Hetzner API token in `pass show sessionhelper/hetzner-api-token` or `HETZNER_API_TOKEN` env var
- SSH key at `~/.ssh/id_ed25519` registered in the Hetzner account
