#!/usr/bin/env bash
# Hetzner Cloud API provider functions.
# Sourced by provision.sh — not executed directly.
# Requires: curl, jq
# Auth: HETZNER_API_TOKEN env var (set by provision.sh from pass or env)

HETZNER_API="https://api.hetzner.cloud/v1"

_hetzner_curl() {
  # Wrapper around curl for Hetzner API calls.
  # First arg is the HTTP method, second is the endpoint path,
  # remaining args are passed to curl (e.g. -d for POST body).
  local method="$1" endpoint="$2"
  shift 2
  curl -sf -X "$method" \
    -H "Authorization: Bearer ${HETZNER_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "$@" \
    "${HETZNER_API}${endpoint}"
}

hetzner_create_server() {
  # Create a server and return "server_id ip_address" on stdout.
  local name="$1" server_type="$2" location="$3" image="$4" ssh_key_name="$5" labels_csv="$6"

  # Build labels JSON object from comma-separated key=value pairs
  local labels_json="{}"
  if [ -n "$labels_csv" ]; then
    labels_json=$(printf '%s' "$labels_csv" | awk -F, '{
      printf "{"
      for (i=1; i<=NF; i++) {
        split($i, kv, "=")
        if (i > 1) printf ","
        printf "\"%s\":\"%s\"", kv[1], kv[2]
      }
      printf "}"
    }')
  fi

  # Resolve the SSH key name to an ID
  local ssh_key_id
  ssh_key_id=$(hetzner_get_ssh_key_id "$ssh_key_name")
  if [ -z "$ssh_key_id" ]; then
    echo "ERROR: SSH key '${ssh_key_name}' not found in Hetzner account" >&2
    echo "Upload it with: provision.sh upload-ssh-key" >&2
    return 1
  fi

  local payload
  payload=$(jq -n \
    --arg name "$name" \
    --arg type "$server_type" \
    --arg loc "$location" \
    --arg img "$image" \
    --argjson keys "[$ssh_key_id]" \
    --argjson labels "$labels_json" \
    '{
      name: $name,
      server_type: $type,
      location: $loc,
      image: $img,
      ssh_keys: $keys,
      labels: $labels,
      start_after_create: true
    }')

  local response
  response=$(_hetzner_curl POST /servers -d "$payload") || {
    echo "ERROR: Hetzner API call failed" >&2
    echo "$response" >&2
    return 1
  }

  local server_id ip
  server_id=$(printf '%s' "$response" | jq -r '.server.id')
  ip=$(printf '%s' "$response" | jq -r '.server.public_net.ipv4.ip')

  if [ "$server_id" = "null" ] || [ -z "$server_id" ]; then
    echo "ERROR: Failed to parse server ID from response" >&2
    printf '%s' "$response" | jq . >&2
    return 1
  fi

  printf '%s %s\n' "$server_id" "$ip"
}

hetzner_delete_server() {
  local server_id="$1"
  _hetzner_curl DELETE "/servers/${server_id}" > /dev/null || {
    echo "ERROR: Failed to delete server ${server_id}" >&2
    return 1
  }
}

hetzner_list_servers() {
  # List servers matching a label selector. Outputs TSV: id name ip status type
  local label_selector="${1:-project=sessionhelper}"
  local response
  response=$(_hetzner_curl GET "/servers?label_selector=$(printf '%s' "$label_selector" | jq -sRr @uri)") || {
    echo "ERROR: Failed to list servers" >&2
    return 1
  }
  printf '%s' "$response" | jq -r '.servers[] | [.id, .name, .public_net.ipv4.ip, .status, .server_type.name] | @tsv'
}

hetzner_get_server() {
  # Get a single server's details. Outputs: ip status
  local server_id="$1"
  local response
  response=$(_hetzner_curl GET "/servers/${server_id}") || {
    echo "ERROR: Failed to get server ${server_id}" >&2
    return 1
  }
  local ip status
  ip=$(printf '%s' "$response" | jq -r '.server.public_net.ipv4.ip')
  status=$(printf '%s' "$response" | jq -r '.server.status')
  printf '%s %s\n' "$ip" "$status"
}

hetzner_get_ssh_key_id() {
  # Look up an SSH key by name, return its ID.
  local key_name="$1"
  local response
  response=$(_hetzner_curl GET "/ssh_keys?name=${key_name}") || return 1
  printf '%s' "$response" | jq -r '.ssh_keys[0].id // empty'
}

hetzner_upload_ssh_key() {
  # Upload a local SSH public key to the Hetzner account.
  local key_name="$1" pubkey_path="$2"
  if [ ! -f "$pubkey_path" ]; then
    echo "ERROR: Public key file not found: ${pubkey_path}" >&2
    return 1
  fi
  local pubkey
  pubkey=$(cat "$pubkey_path")
  local payload
  payload=$(jq -n --arg name "$key_name" --arg key "$pubkey" '{name: $name, public_key: $key}')
  local response
  response=$(_hetzner_curl POST /ssh_keys -d "$payload") || {
    echo "ERROR: Failed to upload SSH key" >&2
    echo "$response" >&2
    return 1
  }
  printf '%s' "$response" | jq -r '.ssh_key.id'
}
