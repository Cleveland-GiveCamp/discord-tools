#!/usr/bin/env bash
# duplicate-role.sh
# Duplicates a Discord role's permissions to a new role (by name).
#
# Usage:
#   ./duplicate-role.sh "<source_role_name>" "<new_role_name>"
#
# Environment variables required:
#   DISCORD_BOT_TOKEN  - your bot token
#   DISCORD_SERVER_ID  - the server ID
#
# Requires: curl, jq

set -euo pipefail

# ── helpers ──────────────────────────────────────────────────────────────────

die() { echo "error: $*" >&2; exit 1; }

require() {
  command -v "$1" &>/dev/null || die "'$1' is required but not installed."
}

# ── load .env if present ─────────────────────────────────────────────────────

# Looks for .env in the directory the script is invoked from, not the script's
# own directory, so it works naturally when called via `nix run`.
if [[ -f ".env" ]]; then
  # Only export lines that are KEY=VALUE (skip comments and blank lines)
  set -o allexport
  # shellcheck source=/dev/null
  source ".env"
  set +o allexport
fi

# ── validation ────────────────────────────────────────────────────────────────

require curl
require jq

if [[ -z "${DISCORD_BOT_TOKEN:-}" ]]; then die "DISCORD_BOT_TOKEN is not set. Set it in the environment or a .env file."; fi
if [[ -z "${DISCORD_SERVER_ID:-}"  ]]; then die "DISCORD_SERVER_ID is not set. Set it in the environment or a .env file."; fi
if [[ $# -ne 2 ]];                     then die "Usage: $0 \"<source_role_name>\" \"<new_role_name>\""; fi

SOURCE_NAME="$1"
NEW_NAME="$2"
API="https://discord.com/api/v10"
AUTH="Authorization: Bot ${DISCORD_BOT_TOKEN}"

# ── fetch all roles ───────────────────────────────────────────────────────────

echo "Fetching roles for server ${DISCORD_SERVER_ID}..."

ROLES=$(curl -sf \
  -H "$AUTH" \
  "${API}/guilds/${DISCORD_SERVER_ID}/roles")

# Check for API error
if echo "$ROLES" | jq -e '.code' &>/dev/null; then
  die "Discord API error: $(echo "$ROLES" | jq -r '.message')"
fi

# ── find source role ──────────────────────────────────────────────────────────

SOURCE_ROLE=$(echo "$ROLES" | jq --arg name "$SOURCE_NAME" \
  '.[] | select(.name == $name)')

[[ -z "$SOURCE_ROLE" ]] && die "Role '${SOURCE_NAME}' not found in server."

SOURCE_ID=$(echo "$SOURCE_ROLE"          | jq -r '.id')
SOURCE_PERMISSIONS=$(echo "$SOURCE_ROLE" | jq -r '.permissions')
SOURCE_COLOR=$(echo "$SOURCE_ROLE"       | jq -r '.color')
SOURCE_HOIST=$(echo "$SOURCE_ROLE"       | jq -r '.hoist')
SOURCE_MENTIONABLE=$(echo "$SOURCE_ROLE" | jq -r '.mentionable')

echo "Found source role:"
echo "  ID:          ${SOURCE_ID}"
echo "  Permissions: ${SOURCE_PERMISSIONS}"
echo "  Color:       ${SOURCE_COLOR}"
echo "  Hoist:       ${SOURCE_HOIST}"
echo "  Mentionable: ${SOURCE_MENTIONABLE}"

# ── create or update target role ─────────────────────────────────────────────

EXISTING=$(echo "$ROLES" | jq --arg name "$NEW_NAME" \
  '.[] | select(.name == $name)')

PAYLOAD=$(jq -n \
  --arg     name        "$NEW_NAME" \
  --arg     permissions "$SOURCE_PERMISSIONS" \
  --argjson color       "$SOURCE_COLOR" \
  --argjson mentionable "$SOURCE_MENTIONABLE" \
  '{
    name:        $name,
    permissions: $permissions,
    color:       $color,
    hoist:       true,
    mentionable: $mentionable
  }')

if [[ -n "$EXISTING" ]]; then
  EXISTING_ID=$(echo "$EXISTING" | jq -r '.id')
  echo ""
  echo "Role '${NEW_NAME}' already exists (ID: ${EXISTING_ID}), updating permissions..."

  RESULT=$(curl -s \
    -X PATCH \
    -H "$AUTH" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "${API}/guilds/${DISCORD_SERVER_ID}/roles/${EXISTING_ID}")

  if echo "$RESULT" | jq -e '.code' &>/dev/null; then
    die "Discord API error: $(echo "$RESULT" | jq -r '.message')"
  fi

  echo ""
  echo "Done! Role updated:"
  echo "  Name: ${NEW_NAME}"
  echo "  ID:   ${EXISTING_ID}"
else
  echo ""
  echo "Creating new role '${NEW_NAME}'..."

  RESULT=$(curl -s \
    -X POST \
    -H "$AUTH" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "${API}/guilds/${DISCORD_SERVER_ID}/roles")

  if echo "$RESULT" | jq -e '.code' &>/dev/null; then
    die "Discord API error: $(echo "$RESULT" | jq -r '.message')"
  fi

  NEW_ID=$(echo "$RESULT" | jq -r '.id')

  echo ""
  echo "Done! New role created:"
  echo "  Name: ${NEW_NAME}"
  echo "  ID:   ${NEW_ID}"
fi

# ── disable hoist and mentionable on source role ─────────────────────────────

echo ""
echo "Disabling 'display separately' and '@mention' on source role '${SOURCE_NAME}'..."

HOIST_RESULT=$(curl -s \
  -X PATCH \
  -H "$AUTH" \
  -H "Content-Type: application/json" \
  -d '{"hoist":false,"mentionable":false}' \
  "${API}/guilds/${DISCORD_SERVER_ID}/roles/${SOURCE_ID}")

if echo "$HOIST_RESULT" | jq -e '.code' &>/dev/null; then
  die "Discord API error while updating source role: $(echo "$HOIST_RESULT" | jq -r '.message')"
fi

echo "Done! Source role '${SOURCE_NAME}' hoist and mentionable disabled."
