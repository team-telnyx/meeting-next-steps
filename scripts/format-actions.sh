#!/usr/bin/env bash
# Format action items JSON into a clean Slack message and post to DM
# Reads JSON from stdin (output of meeting-next-steps.sh)
set -euo pipefail

DRY_RUN="${DRY_RUN:-false}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

CONFIG_PATH="${CONFIG_PATH:-./config/config.json}"
DM_CHANNEL=$(jq -r '.slack.dm_channel' "$CONFIG_PATH" 2>/dev/null || echo "")
INCLUDE_OTHERS=$(jq -r '.output.include_others_tasks // true' "$CONFIG_PATH" 2>/dev/null || echo "true")

if [[ "$DRY_RUN" != "true" && -z "${SLACK_BOT_TOKEN:-}" ]]; then
  echo "ERROR: SLACK_BOT_TOKEN is not set" >&2
  exit 1
fi

input=$(cat)
timestamp=$(echo "$input" | jq -r '.timestamp')
my_total=$(echo "$input" | jq -r '.your_total_action_items')
meeting_count=$(echo "$input" | jq '.meetings | length')

if [[ "$my_total" -eq 0 ]]; then
  echo "✅ No action items to format — nothing to send" >&2
  exit 0
fi

# Build the Slack message
message="📋 *Meeting Next Steps — $(date +"%b %d, %Y")*\n"
message+="$my_total action item(s) for you from $meeting_count meeting(s)\n"

for i in $(seq 0 $((meeting_count - 1))); do
  meeting=$(echo "$input" | jq ".meetings[$i]")
  name=$(echo "$meeting" | jq -r '.meeting_name')
  date_str=$(echo "$meeting" | jq -r '.meeting_date')
  source=$(echo "$meeting" | jq -r '.source')
  your_count=$(echo "$meeting" | jq -r '.your_task_count')
  others_count=$(echo "$meeting" | jq -r '.others_task_count')

  # Skip meetings with no tasks for the CSM
  [[ "$your_count" -eq 0 && "$INCLUDE_OTHERS" != "true" ]] && continue
  [[ "$your_count" -eq 0 && "$others_count" -eq 0 ]] && continue

  source_tag=""
  [[ "$source" == "gmail_gemini" ]] && source_tag=" _(Gemini)_"

  message+="\n🔵 *${name}*${source_tag} (${date_str})"

  # Your tasks
  if [[ "$your_count" -gt 0 ]]; then
    message+="\n  *Your tasks:*"
    for j in $(seq 0 $((your_count - 1))); do
      task_title=$(echo "$meeting" | jq -r ".your_tasks[$j].title // .your_tasks[$j].text // .your_tasks[$j].description // \"(no description)\"")
      message+="\n    • $task_title"
    done
  fi

  # Others' tasks (if configured)
  if [[ "$INCLUDE_OTHERS" == "true" && "$others_count" -gt 0 ]]; then
    message+="\n  _Others' tasks:_"
    for j in $(seq 0 $((others_count - 1))); do
      task=$(echo "$meeting" | jq ".others_tasks[$j]")
      task_title=$(echo "$task" | jq -r '.title // .text // .description // "(no description)"')
      assignee=$(echo "$task" | jq -r '.assignee.name // .assignee_name // "someone"')
      message+="\n    • @${assignee}: $task_title"
    done
  fi

  # Note for Gemini-sourced items
  note=$(echo "$meeting" | jq -r '.note // empty' 2>/dev/null || true)
  if [[ -n "$note" ]]; then
    message+="\n    _⚠️ ${note}_"
  fi
done

# --- Post to Slack ---
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[DRY-RUN] Would post to $DM_CHANNEL:" >&2
  echo -e "$message" >&2
  exit 0
fi

if [[ -z "$DM_CHANNEL" ]]; then
  echo "ERROR: No dm_channel configured" >&2
  echo -e "$message"
  exit 1
fi

payload=$(jq -n --arg channel "$DM_CHANNEL" --arg text "$message" \
  '{ channel: $channel, text: $text, mrkdwn: true }')

response=$(curl --connect-timeout 10 --max-time 30 -s -X POST "https://slack.com/api/chat.postMessage" \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$payload")

ok=$(echo "$response" | jq -r '.ok' 2>/dev/null || echo "false")
if [[ "$ok" == "true" ]]; then
  echo "📨 Posted action items to Slack DM" >&2
else
  error=$(echo "$response" | jq -r '.error // "unknown"' 2>/dev/null || echo "unknown")
  echo "ERROR: Slack post failed: $error" >&2
  # Still output the message so it's not lost
  echo -e "$message"
  exit 1
fi
