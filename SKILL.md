# SKILL: Meeting Next Steps

## Name
meeting-next-steps

## Description
Post-meeting action item extractor. Pulls notes from Fellow.app and Gmail (Gemini meeting notes), extracts action items, splits by assignee, and DMs the CSM their specific next steps. Only notifies when the CSM has action items from meetings they attended.

## Schedule
Cron: `33 15 * * 1-5` (3:33 PM CT, Monday–Friday)

## Commands
```bash
# Check last 24h of meetings, output to stdout
bash scripts/meeting-next-steps.sh

# Check last N days
bash scripts/meeting-next-steps.sh --days 3

# Dry run — no Slack, no side effects
bash scripts/meeting-next-steps.sh --dry-run

# Save results to file
bash scripts/meeting-next-steps.sh --output results.json

# Run and post to Slack DM
bash scripts/meeting-next-steps.sh --slack

# Format actions for Slack (pipe from main script)
bash scripts/meeting-next-steps.sh | bash scripts/format-actions.sh

# Dry run Slack formatting
bash scripts/meeting-next-steps.sh | bash scripts/format-actions.sh --dry-run
```

## Environment Variables
| Variable | Required | Description |
|----------|----------|-------------|
| `FELLOW_API_KEY` | Yes | Fellow.app API key |
| `SLACK_BOT_TOKEN` | For --slack | Slack bot token with `chat:write` scope |
| `CONFIG_PATH` | No | Path to config JSON (default: `./config/config.json`) |
| `DRY_RUN` | No | Set `true` to enable dry-run mode |

## Built-in Resilience
- **Config validation** runs at startup — catches missing/invalid settings early
- **Retry logic** — 3 attempts with exponential backoff on transient failures
- **Curl timeouts** — 10s connect, 30s max per request
- **Attendee filtering** — skips meetings where CSM wasn't present
- **Smart notify** — only DMs if CSM has personal action items

## Dependencies
- `bash`, `curl`, `jq`
- `/opt/homebrew/bin/gog` CLI (Gmail access)
- Network access to `api.fellow.app`

## Author
team-telnyx / CSM team

## Tags
meetings, action-items, fellow, gmail, gemini, slack, productivity, cron
