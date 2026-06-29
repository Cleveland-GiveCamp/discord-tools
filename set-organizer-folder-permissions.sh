#!/usr/bin/env bash
# set-organizer-folder-permissions.sh
# Sets permission overwrites for the Organizer role on the "Organizers"
# category channel and every child channel inside it.
# The category name is automatically set to "Organizers".
#
# Usage:
#   ./set-organizer-folder-permissions.sh [--run] "<year>"
#
#   Dry-run mode is the default — current overwrites are printed without making
#   any changes. Pass --run to actually apply the permission overwrites.
#
# Examples:
#   ./set-organizer-folder-permissions.sh 2026
#   ./set-organizer-folder-permissions.sh 2026 --run
#
# The role name is constructed as "<year> Organizer". The category targeted is
# always "Organizers".
#
# Permission sets applied:
#   Organizer   — View, Send, Manage Messages, Manage Threads, Embed Links,
#                 Attach Files, Read History, Add Reactions, Mention Everyone,
#                 Create Public Threads, Send Messages in Threads, Send Polls
#
# Environment variables required:
#   DISCORD_BOT_TOKEN  - your bot token
#   DISCORD_SERVER_ID  - the server ID
#
# Requires: curl, jq

set -euo pipefail

# ── helpers ───────────────────────────────────────────────────────────────────

die()     { echo "error: $*" >&2; exit 1; }
info()    { echo "$*"; }
require() { command -v "$1" &>/dev/null || die "'$1' is required but not installed."; }

# ── load .env if present ──────────────────────────────────────────────────────

if [[ -f ".env" ]]; then
  set -o allexport
  # shellcheck source=/dev/null
  source ".env"
  set +o allexport
fi

# ── argument parsing ──────────────────────────────────────────────────────────

DRY_RUN=true

args=()
for arg in "$@"; do
  case "$arg" in
    --run) DRY_RUN=false ;;
    *)     args+=("$arg") ;;
  esac
done

[[ ${#args[@]} -ne 1 ]] && die "Usage: $0 [--run] \"<year>\""

YEAR="${args[0]}"
CATEGORY_NAME="Organizers"

ORGANIZER_ROLE="${YEAR} Organizer"

# ── validation ────────────────────────────────────────────────────────────────

require curl
require jq

[[ -z "${DISCORD_BOT_TOKEN:-}" ]] && die "DISCORD_BOT_TOKEN is not set. Set it in the environment or a .env file."
[[ -z "${DISCORD_SERVER_ID:-}"  ]] && die "DISCORD_SERVER_ID is not set. Set it in the environment or a .env file."

API="https://discord.com/api/v10"
AUTH="Authorization: Bot ${DISCORD_BOT_TOKEN}"

# ── permission bitfields ──────────────────────────────────────────────────────
#
# All channel-applicable permissions and how they are configured per role.
# "on" = explicitly allowed   "off" = not set (neutral; falls back to role/guild default)
# @everyone: allow=0, deny covers all bits 0–52 (every current permission).
# Named roles: deny=0 (no permissions are explicitly denied for them).
#
# | Permission                  | Bit  | Bitmask (hex)        | Organizer  | @everyone |
# |-----------------------------|------|----------------------|------------|-----------|
# | CREATE_INSTANT_INVITE       |  0   | 0x0000000000000001   | off        | deny      |
# | MANAGE_CHANNELS             |  4   | 0x0000000000000010   | on         | deny      |
# | ADD_REACTIONS               |  6   | 0x0000000000000040   | on         | deny      |
# | PRIORITY_SPEAKER            |  8   | 0x0000000000000100   | on         | deny      |
# | STREAM                      |  9   | 0x0000000000000200   | on         | deny      |
# | VIEW_CHANNEL                | 10   | 0x0000000000000400   | on         | deny      |
# | SEND_MESSAGES               | 11   | 0x0000000000000800   | on         | deny      |
# | SEND_TTS_MESSAGES           | 12   | 0x0000000000001000   | on         | deny      |
# | MANAGE_MESSAGES             | 13   | 0x0000000000002000   | on         | deny      |
# | EMBED_LINKS                 | 14   | 0x0000000000004000   | on         | deny      |
# | ATTACH_FILES                | 15   | 0x0000000000008000   | on         | deny      |
# | READ_MESSAGE_HISTORY        | 16   | 0x0000000000010000   | on         | deny      |
# | MENTION_EVERYONE            | 17   | 0x0000000000020000   | on         | deny      |
# | USE_EXTERNAL_EMOJIS         | 18   | 0x0000000000040000   | on         | deny      |
# | CONNECT                     | 20   | 0x0000000000100000   | on         | deny      |
# | SPEAK                       | 21   | 0x0000000000200000   | on         | deny      |
# | MUTE_MEMBERS                | 22   | 0x0000000000400000   | on         | deny      |
# | DEAFEN_MEMBERS              | 23   | 0x0000000000800000   | on         | deny      |
# | MOVE_MEMBERS                | 24   | 0x0000000001000000   | on         | deny      |
# | USE_VAD                     | 25   | 0x0000000002000000   | on         | deny      |
# | MANAGE_ROLES                | 28   | 0x0000000010000000   | off        | deny      |
# | MANAGE_WEBHOOKS             | 29   | 0x0000000020000000   | off        | deny      |
# | USE_APPLICATION_COMMANDS    | 31   | 0x0000000080000000   | off        | deny      |
# | MANAGE_EVENTS               | 33   | 0x0000000200000000   | on         | deny      |
# | MANAGE_THREADS              | 34   | 0x0000000400000000   | on         | deny      |
# | CREATE_PUBLIC_THREADS       | 35   | 0x0000000800000000   | on         | deny      |
# | CREATE_PRIVATE_THREADS      | 36   | 0x0000001000000000   | on         | deny      |
# | USE_EXTERNAL_STICKERS       | 37   | 0x0000002000000000   | on         | deny      |
# | SEND_MESSAGES_IN_THREADS    | 38   | 0x0000004000000000   | on         | deny      |
# | USE_EMBEDDED_ACTIVITIES     | 39   | 0x0000008000000000   | off        | deny      |
# | USE_SOUNDBOARD              | 42   | 0x0000040000000000   | off        | deny      |
# | USE_EXTERNAL_SOUNDS         | 45   | 0x0000200000000000   | off        | deny      |
# | SEND_VOICE_MESSAGES         | 46   | 0x0000400000000000   | off        | deny      |
# | SEND_POLLS                  | 49   | 0x0002000000000000   | on         | deny      |

# @everyone role ID always equals the guild ID in Discord
EVERYONE_ID="$DISCORD_SERVER_ID"
EVERYONE_ALLOW=0
EVERYONE_DENY=$(( (1<<53)-1 ))

ORGANIZER_ALLOW=$(( (1<<4)|(1<<6)|(1<<8)|(1<<9)|(1<<10)|(1<<11)|(1<<12)|(1<<13)|(1<<14)|(1<<15)|(1<<16)|(1<<17)|(1<<18)|(1<<20)|(1<<21)|(1<<22)|(1<<23)|(1<<24)|(1<<25)|(1<<33)|(1<<34)|(1<<35)|(1<<36)|(1<<37)|(1<<38)|(1<<49) ))
ORGANIZER_DENY=0

# ── fetch all guild channels ──────────────────────────────────────────────────

info "Fetching channels for server ${DISCORD_SERVER_ID}..."

CHANNELS=$(curl -sf \
  -H "$AUTH" \
  "${API}/guilds/${DISCORD_SERVER_ID}/channels")

if echo "$CHANNELS" | jq -e '.code' &>/dev/null; then
  die "Discord API error: $(echo "$CHANNELS" | jq -r '.message')"
fi

# ── find the category ─────────────────────────────────────────────────────────

# Channel type 4 = GUILD_CATEGORY
CATEGORY=$(echo "$CHANNELS" | jq --arg name "$CATEGORY_NAME" \
  '.[] | select(.type == 4 and .name == $name)')

[[ -z "$CATEGORY" ]] && die "Category '${CATEGORY_NAME}' not found in server."

CATEGORY_ID=$(echo "$CATEGORY" | jq -r '.id')
info "Found category '${CATEGORY_NAME}' (ID: ${CATEGORY_ID})"

# ── find the roles ────────────────────────────────────────────────────────────

info "Fetching roles for server ${DISCORD_SERVER_ID}..."

ROLES=$(curl -sf \
  -H "$AUTH" \
  "${API}/guilds/${DISCORD_SERVER_ID}/roles")

if echo "$ROLES" | jq -e '.code' &>/dev/null; then
  die "Discord API error: $(echo "$ROLES" | jq -r '.message')"
fi

lookup_role_id() {
  local name="$1"
  local id
  id=$(echo "$ROLES" | jq -r --arg n "$name" '.[] | select(.name == $n) | .id')
  [[ -z "$id" ]] && die "Role '${name}' not found in server."
  echo "$id"
}

ORGANIZER_ID=$(lookup_role_id "$ORGANIZER_ROLE")

info "Found roles:"
info "  @everyone        → ${EVERYONE_ID}"
info "  ${ORGANIZER_ROLE} → ${ORGANIZER_ID}"

# ── collect channels to update (category + children) ─────────────────────────

# Build a list of channel IDs: the category first, then all child channels.
CHILD_IDS=$(echo "$CHANNELS" | jq -r --arg pid "$CATEGORY_ID" \
  '.[] | select(.parent_id == $pid) | .id')

TARGET_IDS=("$CATEGORY_ID")
while IFS= read -r id; do
  [[ -n "$id" ]] && TARGET_IDS+=("$id")
done <<< "$CHILD_IDS"

CHILD_COUNT=$(( ${#TARGET_IDS[@]} - 1 ))
info ""
info "Will update category + ${CHILD_COUNT} child channel(s)."

# ── dry-run: print current overwrites ────────────────────────────────────────

if [[ "$DRY_RUN" == true ]]; then
  info ""
  info "=== DRY RUN — no changes will be applied ==="

  print_overwrite() {
    local channel_id="$1"
    local role_id="$2"
    local role_name="$3"
    local expected_allow="$4"
    local expected_deny="$5"

    local ch_data
    ch_data=$(echo "$CHANNELS" | jq --arg id "$channel_id" '.[] | select(.id == $id)')

    local ch_name
    ch_name=$(echo "$ch_data" | jq -r '.name')

    local overwrite
    overwrite=$(echo "$ch_data" | jq --arg rid "$role_id" \
      '.permission_overwrites // [] | .[] | select(.id == $rid)')

    if [[ -z "$overwrite" ]]; then
      local actual_allow=0 actual_deny=0
    else
      local actual_allow actual_deny
      actual_allow=$(echo "$overwrite" | jq -r '.allow')
      actual_deny=$(echo  "$overwrite" | jq -r '.deny')
    fi

    if [[ "$actual_allow" -eq "$expected_allow" && "$actual_deny" -eq "$expected_deny" ]]; then
      echo "    OK       ${ch_name} (${ch_id})"
    else
      echo "    MISMATCH ${ch_name} (${ch_id})"
      echo "             allow:  actual=${actual_allow}  expected=${expected_allow}"
      echo "             deny:   actual=${actual_deny}  expected=${expected_deny}"
    fi
  }

  for role_id in "$EVERYONE_ID" "$ORGANIZER_ID"; do
    case "$role_id" in
      "$EVERYONE_ID")  role_name="@everyone"      expected_allow="$EVERYONE_ALLOW"  expected_deny="$EVERYONE_DENY"  ;;
      "$ORGANIZER_ID") role_name="$ORGANIZER_ROLE" expected_allow="$ORGANIZER_ALLOW" expected_deny="$ORGANIZER_DENY" ;;
    esac

    info ""
    info "  Role: ${role_name} (${role_id})"
    for ch_id in "${TARGET_IDS[@]}"; do
      print_overwrite "$ch_id" "$role_id" "$role_name" "$expected_allow" "$expected_deny"
    done
  done

  info ""
  info "Done (dry run)."
  exit 0
fi

# ── apply overwrites ──────────────────────────────────────────────────────────

apply_overwrite() {
  local channel_id="$1"
  local role_id="$2"
  local allow="$3"
  local deny="$4"
  local label="$5"

  local payload
  payload=$(jq -n \
    --arg allow "$allow" \
    --arg deny  "$deny"  \
    --argjson type 0     \
    '{ allow: $allow, deny: $deny, type: $type }')

  local result
  result=$(curl -s \
    -X PUT \
    -H "$AUTH" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${API}/channels/${channel_id}/permissions/${role_id}")

  # PUT /channels/{id}/permissions/{overwrite_id} returns 204 No Content on
  # success, so an empty response is expected.  Only fail if we get JSON back
  # that contains a Discord error code.
  if echo "$result" | jq -e '.code' &>/dev/null 2>&1; then
    local code message
    code=$(echo "$result"    | jq -r '.code')
    message=$(echo "$result" | jq -r '.message')
    if [[ "$message" == "Missing Access" ]]; then
      echo "  warning: skipped ${label} — bot lacks access to this channel (code ${code})" >&2
    else
      die "Discord API error on ${label}: ${message} (code ${code})"
    fi
  fi
}

set_role_overwrites() {
  local role_id="$1"
  local role_name="$2"
  local allow="$3"
  local deny="$4"

  info ""
  info "Setting overwrites for '${role_name}'..."
  for ch_id in "${TARGET_IDS[@]}"; do
    local ch_name
    ch_name=$(echo "$CHANNELS" | jq -r --arg id "$ch_id" '.[] | select(.id == $id) | .name')
    info "  → ${ch_name} (${ch_id})"
    apply_overwrite "$ch_id" "$role_id" "$allow" "$deny" "${role_name} / ${ch_name}"
  done
}

set_role_overwrites "$ORGANIZER_ID" "$ORGANIZER_ROLE" "$ORGANIZER_ALLOW" "$ORGANIZER_DENY"
set_role_overwrites "$EVERYONE_ID"   "@everyone"        "$EVERYONE_ALLOW"   "$EVERYONE_DENY"

info ""
info "Done! Permission overwrites applied to '${CATEGORY_NAME}' and ${CHILD_COUNT} child channel(s)."
