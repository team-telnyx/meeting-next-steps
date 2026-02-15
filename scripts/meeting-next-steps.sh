#!/usr/bin/env bash
# Meeting Next Steps — extracts action items from Fellow.app and Gmail Gemini notes
# Output: JSON to stdout with meetings and action items split by assignee
set -euo pipefail

# --- Flags ---
OUTPUT_FILE=""
DRY_RUN="${DRY_RUN:-false}"
DAYS=1
POST_SLACK=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT_FILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --days) DAYS="$2"; shift 2 ;;
    --slack) POST_SLACK=true; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

CONFIG_PATH="${CONFIG_PATH:-./config/config.json}"

# --- Dependency checks ---
if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: Config file not found at $CONFIG_PATH" >&2
  echo "Copy config/example-config.json to config/config.json and fill in your data." >&2
  exit 1
fi

for cmd in jq curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required. Install with: brew install $cmd" >&2
    exit 1
  fi
done

# --- Config validation ---
if ! jq empty "$CONFIG_PATH" 2>/dev/null; then
  echo "ERROR: $CONFIG_PATH is not valid JSON" >&2
  exit 1
fi

missing_fields=()
if [[ "$(jq 'has("fellow")' "$CONFIG_PATH")" != "true" ]]; then
  missing_fields+=("fellow")
fi
if [[ "$(jq 'has("filters") and (.filters | has("attendee_email"))' "$CONFIG_PATH")" != "true" ]]; then
  missing_fields+=("filters.attendee_email")
fi
if [[ "$(jq 'has("slack") and (.slack | has("dm_channel"))' "$CONFIG_PATH")" != "true" ]]; then
  missing_fields+=("slack.dm_channel")
fi
if [[ ${#missing_fields[@]} -gt 0 ]]; then
  echo "ERROR: Config missing required fields: ${missing_fields[*]}" >&2
  exit 1
fi

# --- Required env vars (must be set before proceeding) ---
# FELLOW_API_KEY is required via env var — not stored in config for security
FELLOW_API_KEY="${FELLOW_API_KEY:-}"
if [[ -z "$FELLOW_API_KEY" ]]; then
  echo "ERROR: FELLOW_API_KEY is not set (required via env var)" >&2
  exit 1
fi

# --- Load config ---
SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"
FELLOW_BASE_URL=$(jq -r '.fellow.base_url // "https://api.fellow.app/v1"' "$CONFIG_PATH")
GOG_PATH=$(jq -r '.gmail.gog_path // "/opt/homebrew/bin/gog"' "$CONFIG_PATH")
GMAIL_MAX_RESULTS=$(jq -r '.gmail.max_results // 10' "$CONFIG_PATH")
ATTENDEE_EMAIL=$(jq -r '.filters.attendee_email' "$CONFIG_PATH")
DM_CHANNEL=$(jq -r '.slack.dm_channel' "$CONFIG_PATH")
INCLUDE_OTHERS=$(jq -r '.output.include_others_tasks // true' "$CONFIG_PATH")
DATE_FORMAT=$(jq -r '.output.date_format // "%b %d, %Y %I:%M %p"' "$CONFIG_PATH")

# Read ignore list
IGNORE_MEETINGS=$(jq -r '.filters.ignore_meetings // [] | .[]' "$CONFIG_PATH" 2>/dev/null || true)

if [[ "$POST_SLACK" == "true" && -z "$SLACK_BOT_TOKEN" ]]; then
  echo "ERROR: SLACK_BOT_TOKEN is required for --slack mode" >&2
  exit 1
fi

# --- Date calculation ---
if [[ "$(uname)" == "Darwin" ]]; then
  SINCE_DATE=$(date -v-"${DAYS}d" +%Y-%m-%d)
else
  SINCE_DATE=$(date -d "-${DAYS} days" +%Y-%m-%d)
fi
HOURS=$((DAYS * 24))

echo "📋 Checking meetings since $SINCE_DATE ($DAYS day(s))..." >&2

# --- Retry wrapper ---
retry_curl() {
  local attempt=1 max=3 delay=2
  while true; do
    local http_code output
    output=$(curl --connect-timeout 10 --max-time 30 -s -w "\n%{http_code}" "$@" 2>/dev/null) || true
    http_code=$(echo "$output" | tail -1)
    local body
    body=$(echo "$output" | sed '$d')

    if [[ "$http_code" =~ ^2 ]]; then
      echo "$body"
      return 0
    fi

    if [[ $attempt -ge $max ]]; then
      echo "ERROR: Request failed after $max attempts (HTTP $http_code)" >&2
      echo "$body"
      return 1
    fi

    echo "  Retry $attempt/$max after ${delay}s (HTTP $http_code)..." >&2
    sleep "$delay"
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done
}

# ============================================================
# SOURCE 1: Fellow.app
# ============================================================
fellow_meetings="[]"
fellow_actions="[]"

echo "🔍 Checking Fellow.app..." >&2

if [[ "$DRY_RUN" == "true" ]]; then
  echo "  [DRY RUN] Would query: ${FELLOW_BASE_URL}/meetings?start_date=${SINCE_DATE}" >&2
  echo "  [DRY RUN] Would query: ${FELLOW_BASE_URL}/action-items?since=${SINCE_DATE}" >&2
else
  # Fetch meetings
  meetings_raw=$(retry_curl \
    -H "Authorization: Bearer $FELLOW_API_KEY" \
    "${FELLOW_BASE_URL}/meetings?start_date=${SINCE_DATE}" 2>/dev/null) || meetings_raw="[]"

  # Normalize: handle both {results:[...]} and plain array
  if echo "$meetings_raw" | jq -e '.results' &>/dev/null; then
    fellow_meetings=$(echo "$meetings_raw" | jq '.results // []')
  elif echo "$meetings_raw" | jq -e 'type == "array"' &>/dev/null; then
    fellow_meetings="$meetings_raw"
  else
    echo "  WARNING: Unexpected Fellow meetings response format" >&2
    fellow_meetings="[]"
  fi

  meeting_count=$(echo "$fellow_meetings" | jq 'length')
  echo "  Found $meeting_count meeting(s) in Fellow" >&2

  # Fetch action items
  actions_raw=$(retry_curl \
    -H "Authorization: Bearer $FELLOW_API_KEY" \
    "${FELLOW_BASE_URL}/action-items?since=${SINCE_DATE}" 2>/dev/null) || actions_raw="[]"

  if echo "$actions_raw" | jq -e '.results' &>/dev/null; then
    fellow_actions=$(echo "$actions_raw" | jq '.results // []')
  elif echo "$actions_raw" | jq -e 'type == "array"' &>/dev/null; then
    fellow_actions="$actions_raw"
  else
    echo "  WARNING: Unexpected Fellow action-items response format" >&2
    fellow_actions="[]"
  fi

  action_count=$(echo "$fellow_actions" | jq 'length')
  echo "  Found $action_count action item(s) in Fellow" >&2
fi

# ============================================================
# SOURCE 2: Gmail (Gemini Meeting Notes)
# ============================================================
gmail_notes="[]"

echo "🔍 Checking Gmail for Gemini meeting notes..." >&2

if [[ "$DRY_RUN" == "true" ]]; then
  echo "  [DRY RUN] Would search: from:gemini-app.google.com subject:\"Meeting notes\" newer_than:${HOURS}h" >&2
else
  if [[ -x "$GOG_PATH" ]]; then
    # Search for Gemini meeting notes
    search_results=$("$GOG_PATH" gmail search \
      "from:gemini-app.google.com subject:\"Meeting notes\" newer_than:${HOURS}h" \
      --limit "$GMAIL_MAX_RESULTS" 2>/dev/null) || search_results=""

    if [[ -n "$search_results" ]]; then
      # Parse message IDs from search results (gog outputs JSON array or newline-delimited IDs)
      message_ids=()
      if echo "$search_results" | jq -e 'type == "array"' &>/dev/null 2>&1; then
        while IFS= read -r mid; do
          [[ -n "$mid" && "$mid" != "null" ]] && message_ids+=("$mid")
        done < <(echo "$search_results" | jq -r '.[].id // .[].messageId // .[]' 2>/dev/null || echo "")
      else
        while IFS= read -r mid; do
          [[ -n "$mid" ]] && message_ids+=("$mid")
        done <<< "$search_results"
      fi

      if [[ ${#message_ids[@]} -eq 0 ]]; then
        echo "  No parseable message IDs from gog output" >&2
      fi

      gmail_items="[]"
      for mid in "${message_ids[@]}"; do
        [[ -z "$mid" ]] && continue
        msg_body=$("$GOG_PATH" gmail get "$mid" --format full 2>/dev/null) || continue

        # Extract subject for meeting name
        subject=$(echo "$msg_body" | grep -i "^subject:" | head -1 | sed 's/^[Ss]ubject: *//' || echo "Unknown Meeting")
        # Strip "Meeting notes - " prefix if present
        meeting_name=$(echo "$subject" | sed 's/^Meeting notes - //')

        # Extract action items: lines starting with - [ ] or * or • or "Action:" patterns
        actions_text=$(echo "$msg_body" | grep -iE '^\s*[-*•]\s|action.item|next.step|follow.up|TODO' || true)

        if [[ -n "$actions_text" ]]; then
          gmail_item=$(jq -n \
            --arg name "$meeting_name" \
            --arg id "$mid" \
            --arg actions "$actions_text" \
            '{meeting_name: $name, message_id: $id, raw_actions: $actions, source: "gmail_gemini"}')
          gmail_items=$(echo "$gmail_items" | jq --argjson item "$gmail_item" '. + [$item]')
        fi
      done
      gmail_notes="$gmail_items"
    fi

    gmail_count=$(echo "$gmail_notes" | jq 'length')
    echo "  Found $gmail_count Gemini meeting note(s) with action items" >&2
  else
    echo "  WARNING: gog CLI not found at $GOG_PATH — skipping Gmail source" >&2
  fi
fi

# ============================================================
# PROCESS: Filter by attendee, split by assignee
# ============================================================
echo "📊 Processing action items..." >&2

# Build output: one entry per meeting with your_tasks and others_tasks
output_meetings="[]"
my_action_count=0

# --- Process Fellow meetings ---
if [[ "$DRY_RUN" != "true" ]]; then
  meeting_count=$(echo "$fellow_meetings" | jq 'length')
  for i in $(seq 0 $((meeting_count - 1))); do
    meeting=$(echo "$fellow_meetings" | jq ".[$i]")
    meeting_name=$(echo "$meeting" | jq -r '.title // .name // "Unknown Meeting"')
    meeting_date=$(echo "$meeting" | jq -r '.start_date // .date // .started_at // "unknown"')
    meeting_id=$(echo "$meeting" | jq -r '.id // empty')

    # Check ignore list
    should_ignore=false
    while IFS= read -r ignore_pattern; do
      [[ -z "$ignore_pattern" ]] && continue
      if [[ "$meeting_name" == *"$ignore_pattern"* ]]; then
        should_ignore=true
        break
      fi
    done <<< "$IGNORE_MEETINGS"
    [[ "$should_ignore" == "true" ]] && continue

    # Check if CSM was an attendee
    attendee_match=$(echo "$meeting" | jq -r \
      --arg email "$ATTENDEE_EMAIL" \
      '[.attendees // [] | .[] | .email // .user.email // empty] | map(ascii_downcase) | any(. == ($email | ascii_downcase))' 2>/dev/null || echo "false")

    if [[ "$attendee_match" != "true" ]]; then
      echo "  Skipping '$meeting_name' — you weren't an attendee" >&2
      continue
    fi

    # Filter action items for this meeting (with fallback matching)
    meeting_actions="[]"
    if [[ -n "$meeting_id" ]]; then
      meeting_actions=$(echo "$fellow_actions" | jq --arg mid "$meeting_id" \
        '[.[] | select(.meeting_id == ($mid | tonumber) or .meeting_id == $mid)]' 2>/dev/null || echo "[]")
    fi

    # Fallback: if meeting_id match returned nothing, try matching by date + title substring
    if [[ "$(echo "$meeting_actions" | jq 'length')" -eq 0 && -n "$meeting_date" && "$meeting_date" != "unknown" ]]; then
      date_prefix=$(echo "$meeting_date" | cut -c1-10)  # YYYY-MM-DD
      meeting_actions=$(echo "$fellow_actions" | jq \
        --arg date "$date_prefix" \
        --arg title "$meeting_name" \
        '[.[] | select(
          ((.created_at // .date // "") | startswith($date)) and
          ((.meeting_title // .meeting_name // "") | ascii_downcase | contains($title | ascii_downcase))
        )]' 2>/dev/null || echo "[]")
      fallback_count=$(echo "$meeting_actions" | jq 'length')
      if [[ "$fallback_count" -gt 0 ]]; then
        echo "  ℹ️  Matched $fallback_count action(s) for '$meeting_name' via date+title fallback" >&2
      fi
    fi

    # Split: your tasks vs others
    your_tasks=$(echo "$meeting_actions" | jq -r \
      --arg email "$ATTENDEE_EMAIL" \
      '[.[] | select((.assignee.email // .assignee_email // "") | ascii_downcase == ($email | ascii_downcase))]' 2>/dev/null || echo "[]")

    others_tasks=$(echo "$meeting_actions" | jq -r \
      --arg email "$ATTENDEE_EMAIL" \
      '[.[] | select((.assignee.email // .assignee_email // "") | ascii_downcase != ($email | ascii_downcase))]' 2>/dev/null || echo "[]")

    your_count=$(echo "$your_tasks" | jq 'length')
    others_count=$(echo "$others_tasks" | jq 'length')
    my_action_count=$((my_action_count + your_count))

    entry=$(jq -n \
      --arg name "$meeting_name" \
      --arg date "$meeting_date" \
      --arg source "fellow" \
      --argjson your_tasks "$your_tasks" \
      --argjson others_tasks "$others_tasks" \
      --argjson your_count "$your_count" \
      --argjson others_count "$others_count" \
      '{
        meeting_name: $name,
        meeting_date: $date,
        source: $source,
        your_task_count: $your_count,
        others_task_count: $others_count,
        your_tasks: $your_tasks,
        others_tasks: $others_tasks
      }')

    output_meetings=$(echo "$output_meetings" | jq --argjson entry "$entry" '. + [$entry]')
    echo "  ✅ $meeting_name — $your_count task(s) for you, $others_count for others" >&2
  done

  # --- Process Gmail/Gemini notes ---
  gmail_count=$(echo "$gmail_notes" | jq 'length')
  for i in $(seq 0 $((gmail_count - 1))); do
    note=$(echo "$gmail_notes" | jq ".[$i]")
    meeting_name=$(echo "$note" | jq -r '.meeting_name')
    raw_actions=$(echo "$note" | jq -r '.raw_actions')

    # For Gmail, we can't easily split by assignee without NLP
    # Treat all extracted items as potential tasks, flag for review
    action_lines=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && action_lines+=("$line")
    done <<< "$raw_actions"

    task_array="[]"
    for line in "${action_lines[@]}"; do
      clean_line=$(echo "$line" | sed 's/^[[:space:]]*[-*•]\s*//' | sed 's/^[[:space:]]*//')
      [[ -z "$clean_line" ]] && continue
      task_array=$(echo "$task_array" | jq --arg t "$clean_line" '. + [{title: $t, source: "gmail_gemini"}]')
    done

    task_count=$(echo "$task_array" | jq 'length')
    my_action_count=$((my_action_count + task_count))

    entry=$(jq -n \
      --arg name "$meeting_name" \
      --arg date "$SINCE_DATE" \
      --arg source "gmail_gemini" \
      --argjson tasks "$task_array" \
      --argjson count "$task_count" \
      '{
        meeting_name: $name,
        meeting_date: $date,
        source: $source,
        your_task_count: $count,
        others_task_count: 0,
        your_tasks: $tasks,
        others_tasks: [],
        note: "Extracted from Gemini notes — verify assignees"
      }')

    output_meetings=$(echo "$output_meetings" | jq --argjson entry "$entry" '. + [$entry]')
    echo "  ✅ $meeting_name (Gemini) — $task_count action item(s)" >&2
  done
fi

# ============================================================
# OUTPUT
# ============================================================

total_meetings=$(echo "$output_meetings" | jq 'length')

final_output=$(jq -n \
  --argjson meetings "$output_meetings" \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg since "$SINCE_DATE" \
  --argjson my_action_count "$my_action_count" \
  --argjson total_meetings "$total_meetings" \
  --arg attendee "$ATTENDEE_EMAIL" \
  --argjson dry_run "$DRY_RUN" \
  '{
    timestamp: $timestamp,
    since_date: $since,
    attendee_email: $attendee,
    total_meetings: $total_meetings,
    your_total_action_items: $my_action_count,
    dry_run: $dry_run,
    meetings: $meetings
  }')

echo "$final_output"

# Save to file if --output
if [[ -n "$OUTPUT_FILE" ]]; then
  echo "$final_output" > "$OUTPUT_FILE"
  echo "📁 Results saved to $OUTPUT_FILE" >&2
fi

# Post to Slack if --slack and there are action items for the CSM
if [[ "$POST_SLACK" == "true" && "$DRY_RUN" != "true" ]]; then
  if [[ "$my_action_count" -gt 0 ]]; then
    echo "📨 Posting to Slack DM ($DM_CHANNEL)..." >&2
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    echo "$final_output" | bash "$SCRIPT_DIR/format-actions.sh"
  else
    echo "✅ No action items for you — skipping Slack notification" >&2
  fi
else
  if [[ "$my_action_count" -eq 0 ]]; then
    echo "✅ No action items found for you in the last $DAYS day(s)" >&2
  else
    echo "✅ Found $my_action_count action item(s) for you across $total_meetings meeting(s)" >&2
  fi
fi
