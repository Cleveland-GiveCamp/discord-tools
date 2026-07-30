#!/usr/bin/env bash
# find-duplicate-year-roles.sh
# Finds members that hold more than one year-scoped role for the given year
# (i.e. any combination of "<year> Organizer", "<year> Nonprofit", and
# "<year> Volunteer") and, in --run mode, removes the lower-priority role(s).
#
# Priority order (highest → lowest):
#   1. <year> Organizer
#   2. <year> Nonprofit
#   3. <year> Volunteer
#
# When a member holds more than one of the three roles the script keeps only
# the highest-priority role and removes the rest.
#
# Usage:
#   ./find-duplicate-year-roles.sh [--run] "<year>"
#
#   Dry-run mode is the default — affected members are listed without making
#   any changes. Pass --run to actually remove the lower-priority roles.
#
# Examples:
#   ./find-duplicate-year-roles.sh 2026
#   ./find-duplicate-year-roles.sh 2026 --run
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

ORGANIZER_ROLE="${YEAR} Organizer"
NONPROFIT_ROLE="${YEAR} Nonprofit"
VOLUNTEER_ROLE="${YEAR} Volunteer"

# ── validation ────────────────────────────────────────────────────────────────

require curl
require jq

[[ -z "${DISCORD_BOT_TOKEN:-}" ]] && die "DISCORD_BOT_TOKEN is not set. Set it in the environment or a .env file."
[[ -z "${DISCORD_SERVER_ID:-}"  ]] && die "DISCORD_SERVER_ID is not set. Set it in the environment or a .env file."

API="https://discord.com/api/v10"
AUTH="Authorization: Bot ${DISCORD_BOT_TOKEN}"

# ── fetch roles and resolve year-role IDs ─────────────────────────────────────

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
NONPROFIT_ID=$(lookup_role_id "$NONPROFIT_ROLE")
VOLUNTEER_ID=$(lookup_role_id "$VOLUNTEER_ROLE")

info "Found year roles:"
info "  ${ORGANIZER_ROLE} (priority 1) → ${ORGANIZER_ID}"
info "  ${NONPROFIT_ROLE} (priority 2) → ${NONPROFIT_ID}"
info "  ${VOLUNTEER_ROLE} (priority 3) → ${VOLUNTEER_ID}"

# ── fetch all guild members (paginated) ───────────────────────────────────────

info ""
info "Fetching all guild members (this may take a moment for large servers)..."

ALL_MEMBERS="[]"
AFTER=""
PAGE_LIMIT=1000

while true; do
  local_url="${API}/guilds/${DISCORD_SERVER_ID}/members?limit=${PAGE_LIMIT}"
  if [[ -n "$AFTER" ]]; then local_url="${local_url}&after=${AFTER}"; fi

  PAGE=$(curl -s \
    -H "$AUTH" \
    "$local_url")

  if echo "$PAGE" | jq -e '.code' &>/dev/null; then
    die "Discord API error: $(echo "$PAGE" | jq -r '.message')"
  fi

  PAGE_COUNT=$(echo "$PAGE" | jq 'length')
  ALL_MEMBERS=$(echo "$ALL_MEMBERS $PAGE" | jq -s '.[0] + .[1]')

  if [[ "$PAGE_COUNT" -lt "$PAGE_LIMIT" ]]; then
    break
  fi

  # Get the last member's ID to use as the `after` cursor
  AFTER=$(echo "$PAGE" | jq -r '.[-1].user.id')
done

TOTAL_MEMBERS=$(echo "$ALL_MEMBERS" | jq 'length')
info "Fetched ${TOTAL_MEMBERS} member(s)."

# ── find members with duplicate year roles ────────────────────────────────────

# For each member, collect which of the three year roles they hold, then flag
# any member holding more than one.  We also determine the highest-priority
# role to keep and which roles to remove.
#
# Output format (tab-separated, one record per member-to-remove pair):
#   <user_id> <username> <keep_role_name> <keep_role_id> <remove_role_name> <remove_role_id>

CONFLICTS=$(echo "$ALL_MEMBERS" | jq -r \
  --arg org_id  "$ORGANIZER_ID" \
  --arg org_nm  "$ORGANIZER_ROLE" \
  --arg non_id  "$NONPROFIT_ID" \
  --arg non_nm  "$NONPROFIT_ROLE" \
  --arg vol_id  "$VOLUNTEER_ID" \
  --arg vol_nm  "$VOLUNTEER_ROLE" \
  '
  .[] |
  . as $member |
  ($member.roles | contains([$org_id])) as $has_org |
  ($member.roles | contains([$non_id])) as $has_non |
  ($member.roles | contains([$vol_id])) as $has_vol |
  # Only process members with more than one year role
  select( ([$has_org, $has_non, $has_vol] | map(if . then 1 else 0 end) | add) > 1 ) |
  # Determine the highest-priority role to keep
  (if $has_org then {id: $org_id, name: $org_nm}
   elif $has_non then {id: $non_id, name: $non_nm}
   else {id: $vol_id, name: $vol_nm}
   end) as $keep |
  # Emit one record for every role that should be removed
  (
    (if $has_org and $keep.id != $org_id then [{id: $org_id, name: $org_nm}] else [] end) +
    (if $has_non and $keep.id != $non_id then [{id: $non_id, name: $non_nm}] else [] end) +
    (if $has_vol and $keep.id != $vol_id then [{id: $vol_id, name: $vol_nm}] else [] end)
  )[] |
  . as $remove |
  [
    ($member.user.id // "unknown"),
    ($member.user.username // ($member.user.id // "unknown")),
    $keep.name,
    $keep.id,
    $remove.name,
    $remove.id
  ] | @tsv
  ') || true

# ── dry-run: print conflicts ──────────────────────────────────────────────────

if [[ "$DRY_RUN" == true ]]; then
  info ""
  info "=== DRY RUN — no changes will be applied ==="
  info ""

  if [[ -z "$CONFLICTS" ]]; then
    info "No members found with duplicate ${YEAR} year roles."
  else
    CONFLICT_COUNT=$(echo "$CONFLICTS" | wc -l | tr -d ' ')
    info "Found ${CONFLICT_COUNT} role removal(s) needed:"
    info ""
    printf "  %-30s  %-25s  %-25s  %s\n" "User" "Keep" "Remove" "User ID"
    printf "  %-30s  %-25s  %-25s  %s\n" "------------------------------" "-------------------------" "-------------------------" "-------------------"
    while IFS=$'\t' read -r user_id username keep_name _ remove_name _ || [[ -n "$user_id" ]]; do
      printf "  %-30s  %-25s  %-25s  %s\n" "$username" "$keep_name" "$remove_name" "$user_id"
    done <<< "$CONFLICTS"
  fi

  info ""
  info "Done (dry run). Pass --run to apply removals."
  exit 0
fi

# ── apply: remove lower-priority roles ───────────────────────────────────────

if [[ -z "$CONFLICTS" ]]; then
  info ""
  info "No members found with duplicate ${YEAR} year roles. Nothing to do."
  exit 0
fi

REMOVED=0
SKIPPED=0

remove_role() {
  local user_id="$1"
  local role_id="$2"
  local label="$3"

  local result
  result=$(curl -s \
    -X DELETE \
    -H "$AUTH" \
    "${API}/guilds/${DISCORD_SERVER_ID}/members/${user_id}/roles/${role_id}")

  # DELETE returns 204 No Content on success; non-empty response means an error.
  if [[ -n "$result" ]] && echo "$result" | jq -e '.code' &>/dev/null 2>&1; then
    local code message
    code=$(echo "$result"    | jq -r '.code')
    message=$(echo "$result" | jq -r '.message')
    echo "  warning: skipped ${label} — ${message} (code ${code})" >&2
    return 1
  fi
  return 0
}

info ""
info "Removing lower-priority year roles..."

while IFS=$'\t' read -r user_id username keep_name _ remove_name remove_id || [[ -n "$user_id" ]]; do
  info ""
  info "  ${username} (${user_id})"
  info "    keeping  → ${keep_name}"
  info "    removing → ${remove_name}"
  if remove_role "$user_id" "$remove_id" "${username} / ${remove_name}"; then
    info "    done."
    REMOVED=$(( REMOVED + 1 ))
  else
    SKIPPED=$(( SKIPPED + 1 ))
  fi
done <<< "$CONFLICTS"

info ""
info "Done. ${REMOVED} role(s) removed, ${SKIPPED} skipped."
