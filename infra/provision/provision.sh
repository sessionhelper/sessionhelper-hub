#!/usr/bin/env bash
# provision.sh — SSH-based infrastructure provisioning for Session Helper.
# Creates cloud servers, pushes cached artifacts, runs setup scripts.
#
# Usage:
#   ./provision.sh <action> [args] [options]
#
# Actions:
#   up <profile> [--dry-run]  Create and configure a server
#   down <server-id>          Destroy a server
#   list                      Show all active servers
#   ssh <server-id>           SSH into a server
#   status <server-id>        Health check a server
#   upload-ssh-key            Upload local SSH key to provider
#
# Options:
#   --dry-run    Show what would happen without doing it (for 'up')
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/state"
STATE_FILE="${STATE_DIR}/servers.json"
CACHE_DIR="${SCRIPT_DIR}/cache"
PROFILES_DIR="${SCRIPT_DIR}/profiles"
SETUP_DIR="${SCRIPT_DIR}/setup"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"
SSH_WAIT_TIMEOUT=120  # seconds to wait for SSH to come up

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
for cmd in curl jq rsync ssh; do
  if ! command -v "$cmd" > /dev/null 2>&1; then
    echo "ERROR: required command '${cmd}' not found" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# API token resolution
# ---------------------------------------------------------------------------
resolve_api_token() {
  if [ -n "${HETZNER_API_TOKEN:-}" ]; then
    return
  fi
  if command -v pass > /dev/null 2>&1; then
    HETZNER_API_TOKEN=$(pass show sessionhelper/hetzner-api-token 2>/dev/null || true)
  fi
  if [ -z "${HETZNER_API_TOKEN:-}" ]; then
    echo "ERROR: No Hetzner API token found." >&2
    echo "Set HETZNER_API_TOKEN or store it in pass at sessionhelper/hetzner-api-token" >&2
    exit 1
  fi
  export HETZNER_API_TOKEN
}

# ---------------------------------------------------------------------------
# State management
# ---------------------------------------------------------------------------
init_state() {
  mkdir -p "$STATE_DIR"
  if [ ! -f "$STATE_FILE" ]; then
    echo '[]' > "$STATE_FILE"
  fi
}

state_add_server() {
  local id="$1" name="$2" ip="$3" provider="$4" profile="$5"
  local created_at
  created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local tmp
  tmp=$(mktemp)
  jq --arg id "$id" --arg name "$name" --arg ip "$ip" \
     --arg prov "$provider" --arg prof "$profile" --arg ts "$created_at" \
     '. += [{ id: $id, name: $name, ip: $ip, provider: $prov, profile: $prof, created_at: $ts, status: "active" }]' \
     "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

state_remove_server() {
  local id="$1"
  local tmp
  tmp=$(mktemp)
  jq --arg id "$id" 'map(select(.id != $id))' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

state_get_server_ip() {
  local id="$1"
  jq -r --arg id "$id" '.[] | select(.id == $id) | .ip' "$STATE_FILE"
}

state_get_server_provider() {
  local id="$1"
  jq -r --arg id "$id" '.[] | select(.id == $id) | .provider' "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# Provider loading
# ---------------------------------------------------------------------------
load_provider() {
  local provider="$1"
  local provider_file="${SCRIPT_DIR}/providers/${provider}.sh"
  if [ ! -f "$provider_file" ]; then
    echo "ERROR: Unknown provider '${provider}' — no file at ${provider_file}" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$provider_file"
}

# ---------------------------------------------------------------------------
# Profile loading
# ---------------------------------------------------------------------------
load_profile() {
  local profile="$1"
  local profile_file="${PROFILES_DIR}/${profile}.env"
  if [ ! -f "$profile_file" ]; then
    echo "ERROR: Unknown profile '${profile}' — no file at ${profile_file}" >&2
    echo "Available profiles:" >&2
    ls -1 "$PROFILES_DIR"/*.env 2>/dev/null | xargs -I{} basename {} .env >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$profile_file"
}

# ---------------------------------------------------------------------------
# SSH wait — polls until SSH is reachable or timeout
# ---------------------------------------------------------------------------
wait_for_ssh() {
  local ip="$1"
  local elapsed=0
  echo -n "Waiting for SSH on ${ip}..."
  while [ $elapsed -lt $SSH_WAIT_TIMEOUT ]; do
    if ssh ${SSH_OPTS} -i "$SSH_KEY" "root@${ip}" true 2>/dev/null; then
      echo " ready (${elapsed}s)"
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
    echo -n "."
  done
  echo " TIMEOUT after ${SSH_WAIT_TIMEOUT}s"
  return 1
}

# ---------------------------------------------------------------------------
# Generate server name: sh-<profile>-<random4>
# ---------------------------------------------------------------------------
gen_server_name() {
  local profile="$1"
  local rand
  rand=$(head -c 2 /dev/urandom | od -An -tx1 | tr -d ' ')
  printf 'sh-%s-%s' "$profile" "$rand"
}

# ---------------------------------------------------------------------------
# Action: up
# ---------------------------------------------------------------------------
action_up() {
  local profile="${1:-}"
  local dry_run="${2:-}"
  if [ -z "$profile" ]; then
    echo "Usage: provision.sh up <profile> [--dry-run]" >&2
    exit 1
  fi

  load_profile "$profile"
  resolve_api_token
  load_provider "$PROVIDER"
  init_state

  local server_name
  server_name=$(gen_server_name "$profile")

  if [ "$dry_run" = "--dry-run" ]; then
    echo "=== DRY RUN ==="
    echo "Would create server:"
    echo "  Name:        ${server_name}"
    echo "  Provider:    ${PROVIDER}"
    echo "  Server type: ${SERVER_TYPE}"
    echo "  Location:    ${LOCATION}"
    echo "  Image:       ${IMAGE}"
    echo "  SSH key:     ${SSH_KEY_NAME}"
    echo "  Labels:      ${LABELS}"
    echo "  Setup:       ${SETUP_SCRIPT}"
    echo ""
    echo "Cache dirs to sync:"
    for d in ${CACHE_DIRS}; do
      local src="${CACHE_DIR}/${d}"
      if [ -d "$src" ]; then
        echo "  ${src} ($(du -sh "$src" 2>/dev/null | cut -f1))"
      else
        echo "  ${src} (not populated)"
      fi
    done
    echo ""
    echo "Setup scripts to sync:"
    echo "  ${SETUP_DIR}/base.sh"
    echo "  ${SCRIPT_DIR}/${SETUP_SCRIPT}"
    return 0
  fi

  echo "=== Creating server: ${server_name} ==="
  echo "  Provider: ${PROVIDER} | Type: ${SERVER_TYPE} | Location: ${LOCATION}"

  local result
  result=$("${PROVIDER}_create_server" "$server_name" "$SERVER_TYPE" "$LOCATION" "$IMAGE" "$SSH_KEY_NAME" "$LABELS")
  local server_id ip
  server_id=$(echo "$result" | awk '{print $1}')
  ip=$(echo "$result" | awk '{print $2}')

  echo "  Server ID: ${server_id}"
  echo "  IP:        ${ip}"

  state_add_server "$server_id" "$server_name" "$ip" "$PROVIDER" "$profile"

  # Wait for SSH
  wait_for_ssh "$ip" || {
    echo "ERROR: Server created but SSH unreachable. Server ID: ${server_id}" >&2
    echo "You can tear it down with: provision.sh down ${server_id}" >&2
    exit 1
  }

  # Push cache + setup scripts
  echo "=== Syncing artifacts to server ==="
  ssh ${SSH_OPTS} -i "$SSH_KEY" "root@${ip}" "mkdir -p /opt/cache/setup"

  # Sync setup scripts
  rsync -az -e "ssh ${SSH_OPTS} -i ${SSH_KEY}" \
    "${SETUP_DIR}/" "root@${ip}:/opt/cache/setup/"

  # Sync cache dirs specified by profile
  for d in ${CACHE_DIRS}; do
    local src="${CACHE_DIR}/${d}"
    if [ -d "$src" ] && [ "$(ls -A "$src" 2>/dev/null)" ]; then
      echo "  syncing cache/${d}..."
      ssh ${SSH_OPTS} -i "$SSH_KEY" "root@${ip}" "mkdir -p /opt/cache/${d}"
      rsync -az -e "ssh ${SSH_OPTS} -i ${SSH_KEY}" \
        "${src}/" "root@${ip}:/opt/cache/${d}/"
    else
      echo "  skipping cache/${d} (empty or missing)"
    fi
  done

  # Run setup script
  echo "=== Running setup: ${SETUP_SCRIPT} ==="
  ssh ${SSH_OPTS} -i "$SSH_KEY" "root@${ip}" "bash /opt/cache/${SETUP_SCRIPT}" 2>&1 | \
    sed 's/^/  [remote] /'

  echo ""
  echo "=== Server ready ==="
  echo "  ID:      ${server_id}"
  echo "  Name:    ${server_name}"
  echo "  IP:      ${ip}"
  echo "  Profile: ${profile}"
  echo "  SSH:     ssh -i ${SSH_KEY} root@${ip}"
  echo "  Manage:  provision.sh ssh ${server_id}"
}

# ---------------------------------------------------------------------------
# Action: down
# ---------------------------------------------------------------------------
action_down() {
  local server_id="${1:-}"
  if [ -z "$server_id" ]; then
    echo "Usage: provision.sh down <server-id>" >&2
    exit 1
  fi

  init_state
  local provider
  provider=$(state_get_server_provider "$server_id")
  if [ -z "$provider" ]; then
    # Not in local state — try to delete from provider anyway
    echo "WARN: Server ${server_id} not found in local state, attempting provider delete" >&2
    provider="hetzner"
  fi

  resolve_api_token
  load_provider "$provider"

  echo "=== Destroying server ${server_id} ==="
  "${provider}_delete_server" "$server_id"
  state_remove_server "$server_id"
  echo "  Server ${server_id} destroyed."
}

# ---------------------------------------------------------------------------
# Action: list
# ---------------------------------------------------------------------------
action_list() {
  init_state

  # Show local state
  local count
  count=$(jq length "$STATE_FILE")
  if [ "$count" -eq 0 ]; then
    echo "No servers in local state."
  else
    echo "Local state (${count} server(s)):"
    printf "%-12s %-20s %-16s %-10s %-10s %s\n" "ID" "NAME" "IP" "PROVIDER" "PROFILE" "CREATED"
    jq -r '.[] | [.id, .name, .ip, .provider, .profile, .created_at] | @tsv' "$STATE_FILE" | \
      while IFS=$'\t' read -r id name ip prov prof ts; do
        printf "%-12s %-20s %-16s %-10s %-10s %s\n" "$id" "$name" "$ip" "$prov" "$prof" "$ts"
      done
  fi

  # Also query the provider if token is available
  if [ -n "${HETZNER_API_TOKEN:-}" ] || command -v pass > /dev/null 2>&1; then
    resolve_api_token 2>/dev/null && load_provider hetzner 2>/dev/null && {
      echo ""
      echo "Hetzner Cloud (label: project=sessionhelper):"
      printf "%-12s %-20s %-16s %-10s %s\n" "ID" "NAME" "IP" "STATUS" "TYPE"
      hetzner_list_servers "project=sessionhelper" | \
        while IFS=$'\t' read -r id name ip status stype; do
          printf "%-12s %-20s %-16s %-10s %s\n" "$id" "$name" "$ip" "$status" "$stype"
        done
    } || true
  fi
}

# ---------------------------------------------------------------------------
# Action: ssh
# ---------------------------------------------------------------------------
action_ssh() {
  local server_id="${1:-}"
  if [ -z "$server_id" ]; then
    echo "Usage: provision.sh ssh <server-id>" >&2
    exit 1
  fi

  init_state
  local ip
  ip=$(state_get_server_ip "$server_id")
  if [ -z "$ip" ]; then
    echo "ERROR: Server ${server_id} not found in local state" >&2
    exit 1
  fi

  exec ssh -i "$SSH_KEY" "root@${ip}"
}

# ---------------------------------------------------------------------------
# Action: status
# ---------------------------------------------------------------------------
action_status() {
  local server_id="${1:-}"
  if [ -z "$server_id" ]; then
    echo "Usage: provision.sh status <server-id>" >&2
    exit 1
  fi

  init_state
  resolve_api_token

  local provider
  provider=$(state_get_server_provider "$server_id")
  if [ -z "$provider" ]; then
    provider="hetzner"
  fi
  load_provider "$provider"

  local result
  result=$("${provider}_get_server" "$server_id")
  local ip status
  ip=$(echo "$result" | awk '{print $1}')
  status=$(echo "$result" | awk '{print $2}')

  echo "Server ${server_id}:"
  echo "  Provider status: ${status}"
  echo "  IP: ${ip}"

  # SSH health check
  if ssh ${SSH_OPTS} -i "$SSH_KEY" "root@${ip}" "uptime" 2>/dev/null; then
    echo "  SSH: reachable"
    # Check Docker if available
    ssh ${SSH_OPTS} -i "$SSH_KEY" "root@${ip}" \
      "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null" | \
      sed 's/^/  /' || true
  else
    echo "  SSH: unreachable"
  fi
}

# ---------------------------------------------------------------------------
# Action: upload-ssh-key
# ---------------------------------------------------------------------------
action_upload_ssh_key() {
  resolve_api_token
  load_provider hetzner

  local key_name="${1:-sessionhelper}"
  local pubkey="${SSH_KEY}.pub"

  echo "Uploading SSH key '${key_name}' from ${pubkey}..."
  local key_id
  key_id=$(hetzner_upload_ssh_key "$key_name" "$pubkey")
  echo "  Uploaded. Key ID: ${key_id}"
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
action="${1:-}"
shift || true

case "$action" in
  up)
    profile="${1:-}"
    shift || true
    dry_run="${1:-}"
    action_up "$profile" "$dry_run"
    ;;
  down)
    action_down "${1:-}"
    ;;
  list)
    action_list
    ;;
  ssh)
    action_ssh "${1:-}"
    ;;
  status)
    action_status "${1:-}"
    ;;
  upload-ssh-key)
    action_upload_ssh_key "${1:-}"
    ;;
  *)
    echo "Usage: provision.sh <action> [args] [options]"
    echo ""
    echo "Actions:"
    echo "  up <profile> [--dry-run]  Create and configure a server"
    echo "  down <server-id>          Destroy a server"
    echo "  list                      Show all active servers"
    echo "  ssh <server-id>           SSH into a server"
    echo "  status <server-id>        Health check a server"
    echo "  upload-ssh-key [name]     Upload local SSH key to provider"
    echo ""
    echo "Profiles:"
    if [ -d "$PROFILES_DIR" ]; then
      ls -1 "$PROFILES_DIR"/*.env 2>/dev/null | xargs -I{} basename {} .env | sed 's/^/  /'
    fi
    exit 1
    ;;
esac
