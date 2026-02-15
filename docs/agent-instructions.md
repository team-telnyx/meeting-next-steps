# Meeting Next Steps — Agent Instructions

## Purpose
After meetings wrap up, check Fellow.app and Gmail for action items and DM the CSM their specific next steps.

## Cron Setup
Schedule: `33 15 * * 1-5` (3:33 PM CT, Monday–Friday)

### OpenClaw Cron Command
```
cd ~/clawd/skills/meeting-next-steps && source .env && bash scripts/meeting-next-steps.sh --slack
```

### Why 3:33 PM?
Most customer calls happen between 10 AM and 3 PM. Running at 3:33 PM catches the day's meetings while the CSM still has time to act on items before EOD.

### For heavier meeting days
Run a second pass at end of day:
```
# 5:55 PM catch-up
55 17 * * 1-5 cd ~/clawd/skills/meeting-next-steps && source .env && bash scripts/meeting-next-steps.sh --slack
```

## What It Does
1. Queries Fellow.app for meetings in the last 24h
2. Searches Gmail for Gemini-generated meeting notes
3. Filters: only meetings where the CSM was an attendee
4. Extracts action items, splits by assignee
5. **Only DMs the CSM if they have personal action items** (no spam)
6. Message includes: meeting name, date, and specific tasks

## Behavior Rules
- **No notification** if the CSM wasn't on the call
- **No notification** if there are zero action items for the CSM
- Others' tasks are included in the message for context but don't trigger a notification on their own
- Meetings in the `ignore_meetings` config list are skipped (e.g., "Daily Standup")

## Required Environment
- `FELLOW_API_KEY` — Fellow.app API key
- `SLACK_BOT_TOKEN` — Bot token with `chat:write` scope
- `CONFIG_PATH` — Path to config JSON (defaults to `./config/config.json`)
- `/opt/homebrew/bin/gog` — Gmail CLI tool for Gemini note access

## Troubleshooting
- **No Fellow results**: Verify API key is valid; check Fellow API status
- **No Gmail results**: Ensure `gog` is installed and authenticated; verify Gemini is generating meeting notes
- **Slack post fails**: Verify bot token and that the bot can DM the configured channel
- **Missing action items**: Fellow action items must be explicitly created in the meeting; Gemini extraction is best-effort
