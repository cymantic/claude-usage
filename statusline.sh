#!/bin/bash

input=$(cat)

# Extract data
model=$(echo "$input" | jq -r '.model.display_name')
cwd=$(echo "$input" | jq -r '.workspace.current_dir')
session_id=$(echo "$input" | jq -r '.session_id // empty')
session_name=$(echo "$input" | jq -r '.session_name // empty')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
total_input=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
total_output=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
actual_cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')

# Try multiple paths for rate limits
rate_5h=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // .rate_limits.fiveHour.used_percentage // .rate_limits.fiveHour.usedPercentage // .rateLimits.fiveHour.usedPercentage // empty')
rate_7d=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // .rate_limits.sevenDay.used_percentage // .rate_limits.sevenDay.usedPercentage // .rateLimits.sevenDay.usedPercentage // empty')

# Shorten model name
model_short=$(echo "$model" | sed 's/Claude //' | sed 's/ Sonnet//' | sed 's/ Opus//')

# Directory basename
dir_name=$(basename "$cwd")

# LEFT side: model | directory
left="$model_short | $dir_name"

# RIGHT side: context, rate, cost
right=""

# Context percentage
if [ -n "$used_pct" ]; then
    used_rounded=$(printf "%.0f" "$used_pct")
    right="Ctx: ${used_rounded}%"
fi

# Rate limit (5-hour)
if [ -n "$rate_5h" ] && [ "$rate_5h" != "null" ] && [ "$rate_5h" != "" ]; then
    rate_rounded=$(printf "%.0f" "$rate_5h")
    if [ -n "$right" ]; then
        right="$right | Rate: ${rate_rounded}%"
    else
        right="Rate: ${rate_rounded}%"
    fi
fi

# Cost - use actual from JSON
cost="0"
if [ -n "$actual_cost" ] && [ "$actual_cost" != "null" ]; then
    cost=$actual_cost
    cost_display=$(printf "%.2f" "$actual_cost")
    if (( $(echo "$actual_cost >= 0.01" | bc -l) )); then
        if [ -n "$right" ]; then
            right="$right | \$${cost_display}"
        else
            right="\$${cost_display}"
        fi
    fi
fi

# Single line output
echo "$left | $right"

# --- Usage logging to SQLite ---
DB_FILE="$HOME/.claude/usage.db"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DATE_ONLY=$(date -u +"%Y-%m-%d")

# Only log if we have meaningful data
if [ -n "$session_id" ] && [ "$total_input" != "0" ]; then
    # Create table if not exists
    sqlite3 "$DB_FILE" "CREATE TABLE IF NOT EXISTS sessions (
        session_id TEXT PRIMARY KEY,
        session_name TEXT,
        model TEXT,
        directory TEXT,
        tokens_in INTEGER,
        tokens_out INTEGER,
        cost REAL,
        rate_limit_5h REAL,
        rate_limit_7d REAL,
        date TEXT,
        updated_at TEXT
    );" 2>/dev/null

    # Upsert session data
    sqlite3 "$DB_FILE" "INSERT INTO sessions (session_id, session_name, model, directory, tokens_in, tokens_out, cost, rate_limit_5h, rate_limit_7d, date, updated_at)
        VALUES ('$session_id', '${session_name//\'/\'\'}', '${model//\'/\'\'}', '${cwd//\'/\'\'}', $total_input, $total_output, ${cost:-0}, ${rate_5h:-null}, ${rate_7d:-null}, '$DATE_ONLY', '$TIMESTAMP')
        ON CONFLICT(session_id) DO UPDATE SET
            session_name = COALESCE(NULLIF(excluded.session_name, ''), sessions.session_name),
            tokens_in = excluded.tokens_in,
            tokens_out = excluded.tokens_out,
            cost = excluded.cost,
            rate_limit_5h = COALESCE(excluded.rate_limit_5h, sessions.rate_limit_5h),
            rate_limit_7d = COALESCE(excluded.rate_limit_7d, sessions.rate_limit_7d),
            updated_at = excluded.updated_at;" 2>/dev/null
fi

# Save latest rate limits to separate file for easy access
if [ -n "$rate_5h" ] && [ "$rate_5h" != "null" ] && [ "$rate_5h" != "" ]; then
    jq -n \
        --arg ts "$TIMESTAMP" \
        --arg rate_5h "$rate_5h" \
        --arg rate_7d "${rate_7d:-}" \
        '{timestamp: $ts, rate_limit_5h: ($rate_5h | tonumber), rate_limit_7d: (if $rate_7d != "" then ($rate_7d | tonumber) else null end)}' \
        > "$HOME/.claude/rate-limits.json" 2>/dev/null
fi
