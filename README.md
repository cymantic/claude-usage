# Claude Usage Tracking

Track Claude Code usage across sessions and agents, in the terminal and the desktop app, with a custom status line and
SQLite-based reporting.

## Components

| File              | Purpose                                                               |
|-------------------|-----------------------------------------------------------------------|
| `statusline.sh`   | Status bar script that displays context, limits and cost, and records terminal sessions |
| `usage-sync.py`   | Reads every session and agent transcript into SQLite and prices it at API rates       |
| `usage-report.sh` | Runs `usage-sync.py`, then aggregates and reports on usage                              |

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

```
Opus 5.5 | claude-usage (main) | Ctx 13% | Rate 16% 1h 4m | ≈$25.81 API
```

- Model name and current directory, with its git branch
- Context window usage
- The 5-hour limit and the time until it resets; the 7-day limit (`Week`) too once it passes 50%
- Session cost, including the session's agents: `≈… API` on a subscription, where it is what the API would have charged
  rather than money spent

Context and limits turn amber at 70% and red at 90%.

## Usage Tracking

Usage lands in `~/.claude/usage.db` (SQLite) from two sources:

- **`transcripts`**, rebuilt by `usage-sync.py` from `~/.claude/projects`, where every session and agent records the
  tokens of each API call. One row a transcript a day: `session_id`, `agent_id` and `kind` (`session` or `agent`),
  `project` (an agent's worktree counts as its repository), `entrypoint` (`cli` or `claude-desktop`), `model`,
  `requests`, `input_tokens`, `cache_write_tokens`, `cache_read_tokens`, `output_tokens`, `cost` at API rates, and
  `unpriced_requests` for models missing from `PRICES` in `usage-sync.py`. The report's figures come from here.
- **`sessions`**, one row per terminal session, kept up to date by the status line: `session_name` (set with
  `/rename`), `model`, `directory`, `branch`, `context_tokens` (what is in context now, not tokens used), `cost` as
  Claude Code reports it, and the rate limits last seen. The status line doesn't run in the desktop app, so this table
  only names sessions; the report doesn't count from it.

`~/.claude/rate-limits.json` holds the latest limits and their reset times.

Prices in `usage-sync.py` come from the published API rates; add a model there when a new one appears, or the report
says how many calls it couldn't price. Run the tests with `python3 -m unittest discover -s tests`.

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
 Today's Usage (2026-11-23)
═══════════════════════════════════════════════════════════

─── Current Max Plan Usage ───
  5-hour limit:   23.0% used, resets in 1h 4m
  7-day limit:     5.0% used, resets in 2d 2h
  (as of 2026-11-23T21:33:09Z; limits count every session, agent and claude.ai chat)

Total Cost:      $9.72 (API equivalent)
Sessions:        2, with 5 agents
Tokens In:       611,206, plus 13,635,417 read from cache
Tokens Out:      137,181

─── Max Plan Value ───
  Period:            1 days
  Monthly projected: $291.60

  Max 5x  ($100/mo): +$191.60 value
  Max 20x ($200/mo): +$91.60 value

─── By Model ───
  claude-opus-5-5: $9.72 (7 transcripts)

─── By App ───
  claude-desktop: $6.28 (1 sessions)
  cli: $3.45 (1 sessions)

─── Sessions and Agents ───
  sessions: $7.10 (2)
  agents: $2.62 (5)

─── By Project ───
  shop: $6.28 (1 sessions)
  kpis: $3.45 (1 sessions)

─── Recent Sessions (with their agents) ───
  2026-11-23 Checkout redesign: $6.28
  2026-11-23 KPI dashboard: $3.45
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
