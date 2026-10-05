# Claude Usage Tracking

Track Claude Code usage across sessions with a custom status line and SQLite-based reporting.

## Components

| File              | Purpose                                                               |
|-------------------|-----------------------------------------------------------------------|
| `statusline.sh`   | Status bar script that displays context/cost and logs usage to SQLite |
| `usage-report.sh` | Aggregates and reports on usage data                                  |

## Setup

### 1. Install the status line script

Copy the status line script to your Claude config directory:

```bash
cp statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

### 2. Configure Claude Code to use it

Add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```

### 3. Restart Claude Code

The status line will now appear at the bottom showing:
- Model name (e.g., "Opus 4.5")
- Current directory
- Context window usage (%)
- Rate limit usage (% - if available on Max plan)
- Session cost (API equivalent $)

## Usage Tracking

Usage is automatically logged to `~/.claude/usage.db` (SQLite) with one row per session, updated in real-time.

### Data stored per session

- `session_id` - Unique session identifier
- `session_name` - Name if set via `/rename`
- `model` - Model used (e.g., "Opus 4.5")
- `directory` - Working directory/project
- `tokens_in` / `tokens_out` - Token counts
- `cost` - API equivalent cost in USD
- `rate_limit_5h` / `rate_limit_7d` - Max plan rate limits (if available)
- `date` - Session date
- `updated_at` - Last update timestamp

## Reports

Run the report script with a time period:

```bash
./usage-report.sh today      # Today's usage
./usage-report.sh yesterday  # Yesterday's usage
./usage-report.sh week       # Last 7 days
./usage-report.sh month      # Last 30 days
./usage-report.sh all        # All time
./usage-report.sh 2026-06-01 # Specific date
./usage-report.sh dump       # Raw CSV export
```

### Example output

```
═══════════════════════════════════════════════════════════
 Today's Usage (2026-06-04)
═══════════════════════════════════════════════════════════

Total Cost:      $26.63 (API equivalent)
Total Sessions:  3
Tokens In:       156,682
Tokens Out:      147,011

─── Max Plan Value ───
  Period:            1 days
  Monthly projected: $798.90

  Max 5x  ($100/mo): +$698.90 value
  Max 20x ($200/mo): +$598.90 value

─── By Model ───
  Opus 4.5: $26.63 (3 sessions)

─── By Project ───
  kpis: $14.10 (1 sessions)
  scripts: $8.10 (1 sessions)
  universe: $4.42 (1 sessions)

─── Recent Sessions ───
  2026-06-04 scripts: $8.10
  2026-06-04 kpis: $14.10
  2026-06-04 universe: $4.42
```

## Max Plan Value

The report shows your "API equivalent cost" - what you would have paid using the API directly. This helps validate your
Max subscription value:

- **Green**: You're getting more value than your subscription cost
- **Yellow**: You're under-utilizing your subscription

## Dependencies

- `jq` - JSON processing
- `sqlite3` - Database
- `bc` - Math calculations

All typically pre-installed on macOS.

## Automation

For scheduled reports (e.g., via xyOps or cron):

```bash
# Daily summary
0 9 * * * /path/to/usage-report.sh yesterday

# Weekly summary
0 9 * * 1 /path/to/usage-report.sh week
```
