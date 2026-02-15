# Meeting Next Steps

After every customer call, you're scrambling to remember what you committed to. Did you say you'd send that doc? Follow up with engineering? Loop in billing? By the time you're done with back-to-back calls, half of it's gone.

This pulls your action items automatically so nothing falls through the cracks.

## How It Works

Two data sources, one output:

1. **Fellow.app** — Pulls meetings and action items via the Fellow API. If your team uses Fellow for meeting notes, action items are already structured and assigned.

2. **Gmail (Gemini Meeting Notes)** — Google's Gemini auto-generates meeting summaries with action items. This script searches your Gmail for those notes and extracts tasks.

The script checks both sources, filters for meetings where **you** were an attendee, splits action items into "Your tasks" vs "Others' tasks," and only notifies you if **you** have action items. No spam.

## Example Output

```
📋 Meeting Next Steps — Feb 15, 2026

🔵 Weekly Sync with Acme Corp (Feb 15, 2:00 PM)
  Your tasks:
    • Send updated pricing doc to Jamie by EOD Tuesday
    • Open Zendesk ticket for the porting issue
  Others' tasks:
    • @Patrick: Schedule follow-up demo for March
    • @Engineering: Investigate latency on trunk group 42

🔵 Onboarding Check-in: Globex (Feb 15, 3:30 PM)
  Your tasks:
    • Share onboarding checklist template
    • Confirm go-live date with customer
```

Only meetings where you were present. Only action items assigned to you trigger a notification.

## Quick Start

### 1. Clone & Configure

```bash
git clone <repo-url>
cd meeting-next-steps

cp config/example-config.json config/config.json
# Edit config/config.json with your settings
```

### 2. Set Environment Variables

```bash
cp .env.example .env
# Edit .env:
#   FELLOW_API_KEY=your-fellow-api-key
#   SLACK_BOT_TOKEN=xoxb-your-token
```

### 3. Run Manually

```bash
# Check last 24 hours of meetings
bash scripts/meeting-next-steps.sh

# Check last 3 days
bash scripts/meeting-next-steps.sh --days 3

# Dry run — show what would be found without posting
bash scripts/meeting-next-steps.sh --dry-run

# Save output to file
bash scripts/meeting-next-steps.sh --output results.json

# Run and post to Slack DM
bash scripts/meeting-next-steps.sh --slack
```

### 4. Automate with OpenClaw Cron

Schedule for 3:33 PM Mon-Fri (after meetings typically wrap up). See `docs/agent-instructions.md`.

## Data Sources

### Fellow.app
- **Meetings**: `GET /v1/meetings?start_date=YYYY-MM-DD` — lists meetings with attendees
- **Action Items**: `GET /v1/action-items?since=YYYY-MM-DD` — structured tasks with assignees
- Requires `FELLOW_API_KEY` environment variable

### Gmail (Gemini Meeting Notes)
- Searches for emails from `gemini-app.google.com` with subject "Meeting notes"
- Uses the `gog` CLI tool (`/opt/homebrew/bin/gog gmail search` / `gog gmail get`)
- Parses action items from the email body

## Features

- **Retry logic**: API calls retry up to 3 times with exponential backoff
- **Timeouts**: All HTTP requests have connect (10s) and max-time (30s) limits
- **Config validation**: Validates JSON structure and required fields at startup
- **Dry-run mode**: Preview results without posting (`--dry-run` flag)
- **Output to file**: Save results JSON with `--output <file>`
- **Slack DM**: Post your action items directly to your Slack DM (`--slack`)
- **Attendee filtering**: Only processes meetings where the CSM was present
- **Smart notifications**: Only sends a message if YOU have action items

## Requirements

- `bash`, `curl`, `jq`
- `gog` CLI tool (for Gmail access) — `/opt/homebrew/bin/gog`
- Fellow.app API key
- Slack bot token with `chat:write` scope (for `--slack` mode)
- OpenClaw (for automated cron scheduling)

## Security

- **No secrets in the repo.** All tokens via environment variables.
- **No meeting data in the repo.** Everything is fetched at runtime.
- `config/config.json` and `.env` are gitignored.
