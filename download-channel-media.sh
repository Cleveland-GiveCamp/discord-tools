#!/usr/bin/env bash
# download-channel-media.sh
# Finds all images and videos posted in a Discord channel and, in --run mode,
# downloads any that have not already been saved locally.
#
# Dry-run mode is the default — the filenames of images found are printed
# without downloading anything. Pass --run to actually download missing files.
#
# The channel is identified by its ID. The channel name is looked up from the
# API and used in the stored filenames, e.g.:
#   2024-03-15 14-22-00 - general - photo.png
#
# Pass --all-channels instead of a channel ID to scan every text channel in
# the server.
#
# Re-running the script is safe: files that already exist on disk are skipped.
#
# Usage:
#   ./download-channel-media.sh [--run] "<channel_id>" [<output_dir>]
#   ./download-channel-media.sh [--run] --all-channels [<output_dir>]
#
#   Dry-run mode is the default — image filenames are listed without
#   downloading. Pass --run to actually download missing files.
#
# Examples:
#   ./download-channel-media.sh "123456789012345678"
#   ./download-channel-media.sh --run "123456789012345678"
#   ./download-channel-media.sh --run "123456789012345678" ./images
#   ./download-channel-media.sh --all-channels
#   ./download-channel-media.sh --run --all-channels ./images
#
# Environment variables required:
#   DISCORD_BOT_TOKEN  - your bot token
#   DISCORD_SERVER_ID  - the server ID
#
# Privileged intent required:
#   Message Content Intent — must be enabled in the Discord Developer Portal
#   under your bot's Bot → Privileged Gateway Intents settings. Without it the
#   Discord API returns empty attachments arrays and no images will be found.
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
ALL_CHANNELS=false

args=()
for arg in "$@"; do
  case "$arg" in
    --run)          DRY_RUN=false ;;
    --all-channels) ALL_CHANNELS=true ;;
    *)              args+=("$arg") ;;
  esac
done

if [[ "$ALL_CHANNELS" == true ]]; then
  [[ ${#args[@]} -gt 1 ]] && die "Usage: $0 [--run] --all-channels [<output_dir>]"
  OUTPUT_DIR="${args[0]:-.}"
else
  [[ ${#args[@]} -lt 1 || ${#args[@]} -gt 2 ]] && die "Usage: $0 [--run] \"<channel_id>\" [<output_dir>]"
  CHANNEL_ID="${args[0]}"
  OUTPUT_DIR="${args[1]:-.}"
fi

# ── validation ────────────────────────────────────────────────────────────────

require curl
require jq

[[ -z "${DISCORD_BOT_TOKEN:-}" ]] && die "DISCORD_BOT_TOKEN is not set. Set it in the environment or a .env file."
[[ -z "${DISCORD_SERVER_ID:-}"  ]] && die "DISCORD_SERVER_ID is not set. Set it in the environment or a .env file."

if [[ "$DRY_RUN" == false ]]; then
  mkdir -p "$OUTPUT_DIR"
fi

API="https://discord.com/api/v10"
AUTH="Authorization: Bot ${DISCORD_BOT_TOKEN}"

# Media MIME types / filename extensions to collect.
# We check both attachment content_type and filename extension as a fallback.
IMAGE_EXTENSIONS="jpg|jpeg|png|gif|webp|bmp|tiff|tif|svg|avif"
VIDEO_EXTENSIONS="mp4|mov|avi|mkv|webm|flv|wmv|m4v|mpeg|mpg|3gp|ogv"

# ── counters (accumulated across all channels) ────────────────────────────────

TOTAL_DOWNLOADED=0
TOTAL_SKIPPED=0
TOTAL_FAILED=0

# ── discord_get <url> ─────────────────────────────────────────────────────────
# Makes an authenticated GET request, retrying automatically on 429 rate-limit
# responses. On success, prints the response body to stdout and returns 0.
# On a fatal API error (non-rate-limit error code), prints a warning to stderr
# and returns 1. Exits the script on non-JSON or unexpected responses.

discord_get() {
  local request_url="$1"
  local response retry_after

  while true; do
    response=$(curl -s -H "$AUTH" "$request_url")

    # Guard against a completely non-JSON response (e.g. a Cloudflare page).
    if ! echo "$response" | jq -e . &>/dev/null; then
      die "Unexpected non-JSON response from Discord API: ${response}"
    fi

    # A rate-limit response has a `retry_after` field.
    if echo "$response" | jq -e '.retry_after' &>/dev/null; then
      retry_after=$(echo "$response" | jq -r '.retry_after')
      # retry_after is a float (seconds); ceil it to a whole number of seconds.
      local wait
      wait=$(echo "$retry_after" | awk '{print int($1) + ($1 > int($1))}')
      echo "  rate limited — waiting ${wait}s before retrying..." >&2
      sleep "$wait"
      continue
    fi

    # Any other Discord error object has a `code` field.
    if echo "$response" | jq -e '.code' &>/dev/null; then
      local api_msg
      api_msg=$(echo "$response" | jq -r '.message')
      echo "$response"   # return the body so callers can inspect it
      return 1
    fi

    # Success — print the response body.
    echo "$response"
    return 0
  done
}

# ── scan_channel <channel_id> <channel_name> ──────────────────────────────────
# Fetches all messages in the channel, collects image/video attachments, then
# either lists filenames (dry-run) or downloads missing files.

scan_channel() {
  local ch_id="$1"
  local ch_name="$2"

  # Sanitise the channel name for use in filenames:
  # replace any characters that are unsafe in filenames with underscores.
  local ch_prefix
  ch_prefix=$(echo "$ch_name" | tr -cs '[:alnum:]_-' '_' | sed 's/_$//')

  info ""
  info "Fetching messages from #${ch_name} (${ch_id})..."

  local all_media="[]"
  local before=""
  local page_limit=100

  while true; do
    local request_url="${API}/channels/${ch_id}/messages?limit=${page_limit}"
    if [[ -n "$before" ]]; then request_url="${request_url}&before=${before}"; fi

    local page
    if ! page=$(discord_get "$request_url"); then
      local api_msg
      api_msg=$(echo "$page" | jq -r '.message')
      echo "  warning: skipping #${ch_name} — ${api_msg}" >&2
      return
    fi

    local page_count
    page_count=$(echo "$page" | jq 'length')

    # Extract image and video attachments from this page.
    # An attachment is collected if its content_type starts with "image/" or
    # "video/", or if its filename extension matches a known image or video
    # extension. The message timestamp (ISO 8601) is captured so the date and
    # time can be used in the stored filename.
    local page_media
    page_media=$(echo "$page" | jq -r \
      --arg img_exts "$IMAGE_EXTENSIONS" \
      --arg vid_exts "$VIDEO_EXTENSIONS" \
      '
      [
        .[] |
        . as $msg |
        .attachments[]? |
        select(
          (.content_type // "" | startswith("image/")) or
          (.content_type // "" | startswith("video/")) or
          (.filename | ascii_downcase | test("\\.(" + $img_exts + ")$")) or
          (.filename | ascii_downcase | test("\\.(" + $vid_exts + ")$"))
        ) |
        {
          filename: .filename,
          url: .url,
          datetime: (
            ($msg.timestamp | split("T")[0]) + " " +
            ($msg.timestamp | split("T")[1] | split(".")[0] | gsub(":"; "-"))
          )
        }
      ]
      ')

    all_media=$(echo "${all_media} ${page_media}" | jq -s '.[0] + .[1]')

    if [[ "$page_count" -lt "$page_limit" ]]; then
      break
    fi

    # Use the oldest message ID on this page as the `before` cursor.
    before=$(echo "$page" | jq -r '.[-1].id')
  done

  local total_media
  total_media=$(echo "$all_media" | jq 'length')
  info "  Found ${total_media} media attachment(s)."

  if [[ "$total_media" -eq 0 ]]; then
    return
  fi

  # Build target filenames: <datetime> - <channel_name> - <original_filename>
  # e.g. "2024-03-15 14-22-00 - general - photo.png"
  # The URL may include query parameters (e.g. Discord CDN tokens); strip those
  # when deriving the bare filename.
  local media_list
  media_list=$(echo "$all_media" | jq -r \
    --arg prefix "${ch_prefix}" \
    '
    .[] |
    (.filename | gsub("\\?.*$"; "")) as $bare |
    [.datetime + " - " + $prefix + " - " + $bare, .url] | @tsv
    ')

  if [[ "$DRY_RUN" == true ]]; then
    while IFS=$'\t' read -r target_name _ || [[ -n "$target_name" ]]; do
      info "  ${target_name}"
    done <<< "$media_list"
    return
  fi

  # Download missing files.
  while IFS=$'\t' read -r target_name file_url || [[ -n "$target_name" ]]; do
    local dest="${OUTPUT_DIR}/${target_name}"

    if [[ -f "$dest" ]]; then
      info "  skip      ${target_name}"
      TOTAL_SKIPPED=$(( TOTAL_SKIPPED + 1 ))
      continue
    fi

    info "  download  ${target_name}"
    if curl -sf -L -o "$dest" "$file_url"; then
      TOTAL_DOWNLOADED=$(( TOTAL_DOWNLOADED + 1 ))
    else
      echo "  warning: failed to download ${target_name}" >&2
      # Remove any partial file so a re-run will retry it.
      rm -f "$dest"
      TOTAL_FAILED=$(( TOTAL_FAILED + 1 ))
    fi
  done <<< "$media_list"
}

# ── resolve channel list ──────────────────────────────────────────────────────

if [[ "$ALL_CHANNELS" == true ]]; then
  info "Fetching all channels for server ${DISCORD_SERVER_ID}..."

  ALL_GUILD_CHANNELS=$(discord_get "${API}/guilds/${DISCORD_SERVER_ID}/channels") \
    || die "Discord API error: $(echo "$ALL_GUILD_CHANNELS" | jq -r '.message')"

  # Collect text channels only (type 0 = GUILD_TEXT).
  # Each line is tab-separated: <id> <name>
  CHANNEL_LIST=$(echo "$ALL_GUILD_CHANNELS" | jq -r \
    '.[] | select(.type == 0) | [.id, .name] | @tsv')

  CHANNEL_COUNT=$(echo "$CHANNEL_LIST" | grep -c . || true)
  info "Found ${CHANNEL_COUNT} text channel(s)."
else
  info "Fetching channel ${CHANNEL_ID}..."

  CHANNEL=$(discord_get "${API}/channels/${CHANNEL_ID}") \
    || die "Discord API error: $(echo "$CHANNEL" | jq -r '.message')"

  CHANNEL_NAME=$(echo "$CHANNEL" | jq -r '.name')
  [[ -z "$CHANNEL_NAME" || "$CHANNEL_NAME" == "null" ]] && \
    die "Could not resolve a name for channel ${CHANNEL_ID}."

  info "Found channel '${CHANNEL_NAME}' (${CHANNEL_ID})"

  CHANNEL_LIST="${CHANNEL_ID}"$'\t'"${CHANNEL_NAME}"
fi

# ── dry-run header ────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == true ]]; then
  info ""
  info "=== DRY RUN — no files will be downloaded ==="
fi

# ── scan each channel ─────────────────────────────────────────────────────────

while IFS=$'\t' read -r ch_id ch_name || [[ -n "$ch_id" ]]; do
  scan_channel "$ch_id" "$ch_name"
done <<< "$CHANNEL_LIST"

# ── summary ───────────────────────────────────────────────────────────────────

info ""

if [[ "$DRY_RUN" == true ]]; then
  info "Done (dry run). Pass --run to download missing files."
else
  info "Done. ${TOTAL_DOWNLOADED} downloaded, ${TOTAL_SKIPPED} already existed, ${TOTAL_FAILED} failed."
fi
