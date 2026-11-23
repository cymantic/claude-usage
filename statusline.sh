#!/bin/bash
# Claude Code status line: model | directory (branch) | context | rate limits with time to reset | API-equivalent cost.
# Also records each session in ~/.claude/usage.db and the latest limits in ~/.claude/rate-limits.json (README.md).

AMBER=70
RED=90

eval "$(jq -r '
  def secs_left($at): if $at then ($at - now | floor | if . < 0 then 0 else . end) else "" end;
  @sh "session_id=\(.session_id // "")",
  @sh "session_name=\(.session_name // "")",
  @sh "model=\(.model.display_name // "")",
  @sh "cwd=\(.workspace.current_dir // .cwd // "")",
  @sh "context_pct=\(.context_window.used_percentage // "")",
  @sh "context_tokens=\(.context_window.total_input_tokens // "")",
  @sh "cost=\(.cost.total_cost_usd // "")",
  @sh "subscribed=\(if .rate_limits then "yes" else "" end)",
  @sh "rate_5h=\(.rate_limits.five_hour.used_percentage // "")",
  @sh "left_5h=\(secs_left(.rate_limits.five_hour.resets_at))",
  @sh "resets_5h=\(.rate_limits.five_hour.resets_at // "")",
  @sh "rate_7d=\(.rate_limits.seven_day.used_percentage // "")",
  @sh "left_7d=\(secs_left(.rate_limits.seven_day.resets_at))",
  @sh "resets_7d=\(.rate_limits.seven_day.resets_at // "")"
')"

is_number() { [[ $1 =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
rounded() { printf "%.0f" "$1"; }

# A percentage, amber from 70 and red from 90.
coloured() {
  local pct
  pct=$(rounded "$1")
  if (( pct >= RED )); then printf '\033[31m%s%%\033[0m' "$pct"
  elif (( pct >= AMBER )); then printf '\033[33m%s%%\033[0m' "$pct"
  else printf '%s%%' "$pct"; fi
}

# Seconds as the time left: 2d 3h, 1h 4m or 14m.
time_left() {
  local s=$(( ($1 + 59) / 60 * 60 ))  # whole minutes, rounded up
  if (( s >= 86400 )); then printf '%dd %dh' $((s / 86400)) $((s % 86400 / 3600))
  elif (( s >= 3600 )); then printf '%dh %dm' $((s / 3600)) $((s % 3600 / 60))
  else printf '%dm' $((s / 60)); fi
}

# A rate limit and the time until it resets.
limit() {
  local label=$1 pct=$2 left=$3
  printf '%s %s' "$label" "$(coloured "$pct")"
  if is_number "$left"; then printf ' (%s)' "$(time_left "$left")"; fi
}

# What the session has cost: on a subscription that is what the API would have charged, not money spent.
spent() {
  if [ -n "$subscribed" ]; then printf '≈$%.2f API' "$1"; else printf '$%.2f' "$1"; fi
}

branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short -q HEAD 2>/dev/null ||
         git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
where=$(basename "$cwd")
[ -n "$branch" ] && where="$where ($branch)"

parts=("${model#Claude }" "$where")
is_number "$context_pct" && parts+=("Ctx $(coloured "$context_pct")")
is_number "$rate_5h" && parts+=("$(limit Rate "$rate_5h" "$left_5h")")
is_number "$rate_7d" && (( $(rounded "$rate_7d") >= 50 )) && parts+=("$(limit Week "$rate_7d" "$left_7d")")
is_number "$cost" && (( $(rounded "${cost}e2") >= 1 )) && parts+=("$(spent "$cost")")  # from 1 cent

line=""
for part in "${parts[@]}"; do line="${line:+$line | }$part"; done
printf '%b\n' "$line"

# --- Record the session and the latest limits ---

sql_text() { local q="'"; printf "'%s'" "${1//$q/$q$q}"; }  # bash 3.2 keeps \' in a replacement
sql_number() { if is_number "$1"; then printf '%s' "$1"; else printf 'NULL'; fi; }
json_number() { if is_number "$1"; then printf '%s' "$1"; else printf 'null'; fi; }

if [ -n "$session_id" ] && is_number "$context_tokens" && [ "$context_tokens" != "0" ]; then
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  sqlite3 "$HOME/.claude/usage.db" "
    CREATE TABLE IF NOT EXISTS sessions (
      session_id TEXT PRIMARY KEY, session_name TEXT, model TEXT, directory TEXT, branch TEXT,
      context_tokens INTEGER, cost REAL, rate_limit_5h REAL, rate_limit_7d REAL, date TEXT, updated_at TEXT);
    INSERT INTO sessions (session_id, session_name, model, directory, branch, context_tokens, cost, rate_limit_5h,
                          rate_limit_7d, date, updated_at)
    VALUES ($(sql_text "$session_id"), $(sql_text "$session_name"), $(sql_text "$model"), $(sql_text "$cwd"),
            $(sql_text "$branch"), $(sql_number "$context_tokens"), $(sql_number "${cost:-0}"),
            $(sql_number "$rate_5h"), $(sql_number "$rate_7d"), $(sql_text "${now%%T*}"), $(sql_text "$now"))
    ON CONFLICT(session_id) DO UPDATE SET
      session_name = COALESCE(NULLIF(excluded.session_name, ''), sessions.session_name),
      branch = excluded.branch,
      context_tokens = excluded.context_tokens,
      cost = excluded.cost,
      rate_limit_5h = COALESCE(excluded.rate_limit_5h, sessions.rate_limit_5h),
      rate_limit_7d = COALESCE(excluded.rate_limit_7d, sessions.rate_limit_7d),
      updated_at = excluded.updated_at;" 2>/dev/null

  if is_number "$rate_5h"; then
    printf '{"timestamp": "%s", "rate_limit_5h": %s, "rate_limit_7d": %s, "resets_5h": %s, "resets_7d": %s}\n' \
      "$now" "$rate_5h" "$(json_number "$rate_7d")" "$(json_number "$resets_5h")" "$(json_number "$resets_7d")" \
      > "$HOME/.claude/rate-limits.json"
  fi
fi
