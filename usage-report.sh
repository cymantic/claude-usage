#!/bin/zsh

# Claude Code usage report: every session and agent on this Mac, terminal and desktop app, priced at API rates.
# Refreshes the transcripts table with usage-sync.py first; names come from the status line's sessions table.

DB_FILE="$HOME/.claude/usage.db"
HERE="${0:A:h}"

"$HERE/usage-sync.py" || exit 1

REPORT_TYPE="${1:-today}"

case "$REPORT_TYPE" in
    dump|raw)
        sqlite3 -header -csv "$DB_FILE" "SELECT * FROM transcripts ORDER BY last_at DESC;"
        exit 0
        ;;
    today)
        DATE_FILTER=$(date -u +"%Y-%m-%d")
        WHERE_CLAUSE="WHERE t.date = '$DATE_FILTER'"
        TITLE="Today's Usage ($DATE_FILTER)"
        DAYS_IN_PERIOD=1
        ;;
    yesterday)
        DATE_FILTER=$(date -u -v-1d +"%Y-%m-%d")
        WHERE_CLAUSE="WHERE t.date = '$DATE_FILTER'"
        TITLE="Yesterday's Usage ($DATE_FILTER)"
        DAYS_IN_PERIOD=1
        ;;
    week)
        DATE_FILTER=$(date -u -v-7d +"%Y-%m-%d")
        WHERE_CLAUSE="WHERE t.date >= '$DATE_FILTER'"
        TITLE="Last 7 Days Usage (since $DATE_FILTER)"
        DAYS_IN_PERIOD=7
        ;;
    month)
        DATE_FILTER=$(date -u -v-30d +"%Y-%m-%d")
        WHERE_CLAUSE="WHERE t.date >= '$DATE_FILTER'"
        TITLE="Last 30 Days Usage (since $DATE_FILTER)"
        DAYS_IN_PERIOD=30
        ;;
    all)
        WHERE_CLAUSE=""
        TITLE="All Time Usage"
        DAYS_IN_PERIOD=$(sqlite3 "$DB_FILE" "SELECT CAST(julianday('now') - julianday(MIN(date)) AS INTEGER) + 1 FROM transcripts;")
        [[ $DAYS_IN_PERIOD -lt 1 ]] && DAYS_IN_PERIOD=1
        ;;
    <->-<->-<->)
        DATE_FILTER="$1"
        WHERE_CLAUSE="WHERE t.date = '$DATE_FILTER'"
        TITLE="Usage for $DATE_FILTER"
        DAYS_IN_PERIOD=1
        ;;
    *)
        echo "usage: usage-report.sh [today|yesterday|week|month|all|YYYY-MM-DD|dump]" >&2
        exit 1
        ;;
esac

query() { sqlite3 -separator '|' "$DB_FILE" "$1"; }

# Seconds as the time left: 2d 3h, 1h 4m or 14m.
time_left() {
    local s=$(( ($1 + 59) / 60 * 60 ))
    if (( s >= 86400 )); then printf '%dd %dh' $((s / 86400)) $((s % 86400 / 3600))
    elif (( s >= 3600 )); then printf '%dh %dm' $((s / 3600)) $((s % 3600 / 60))
    else printf '%dm' $((s / 60)); fi
}

# A limit from rate-limits.json, with the time until it resets if that is still ahead.
show_limit() {
    local label=$1 pct=$2 resets=$3 left
    [[ -z "$pct" || "$pct" == "null" ]] && return
    printf "  %-14s %5.1f%% used" "$label" "$pct"
    if [[ -n "$resets" && "$resets" != "null" ]]; then
        left=$(( resets - $(date +%s) ))
        (( left > 0 )) && printf ", resets in %s" "$(time_left $left)"
    fi
    printf "\n"
}

echo "═══════════════════════════════════════════════════════════"
echo " $TITLE"
echo "═══════════════════════════════════════════════════════════"
echo ""

RATE_FILE="$HOME/.claude/rate-limits.json"
if [[ -f "$RATE_FILE" ]]; then
    echo "─── Current Max Plan Usage ───"
    show_limit "5-hour limit:" "$(jq -r '.rate_limit_5h // empty' "$RATE_FILE")" "$(jq -r '.resets_5h // empty' "$RATE_FILE")"
    show_limit "7-day limit:" "$(jq -r '.rate_limit_7d // empty' "$RATE_FILE")" "$(jq -r '.resets_7d // empty' "$RATE_FILE")"
    echo "  (as of $(jq -r '.timestamp' "$RATE_FILE"); limits count every session, agent and claude.ai chat)"
    echo ""
fi

IFS='|' read TOTAL_COST SESSIONS AGENTS INPUT CACHE_READ OUTPUT UNPRICED <<< "$(query "
    SELECT COALESCE(SUM(cost), 0), COUNT(DISTINCT session_id), COALESCE(SUM(kind = 'agent'), 0),
           COALESCE(SUM(input_tokens + cache_write_tokens), 0), COALESCE(SUM(cache_read_tokens), 0),
           COALESCE(SUM(output_tokens), 0), COALESCE(SUM(unpriced_requests), 0)
    FROM transcripts t $WHERE_CLAUSE;")"

printf "Total Cost:      \$%.2f (API equivalent)\n" "$TOTAL_COST"
printf "Sessions:        %d, with %d agents\n" "$SESSIONS" "$AGENTS"
printf "Tokens In:       %'d, plus %'d read from cache\n" "$INPUT" "$CACHE_READ"
printf "Tokens Out:      %'d\n" "$OUTPUT"
(( UNPRICED > 0 )) && printf "Not priced:      %d calls to models missing from usage-sync.py\n" "$UNPRICED"
echo ""

echo "─── Max Plan Value ───"
MAX_5X=100
MAX_20X=200
MONTHLY_PROJECTED=$(echo "scale=2; $TOTAL_COST * 30 / $DAYS_IN_PERIOD" | bc)
printf "  Period:            %d days\n" "$DAYS_IN_PERIOD"
printf "  Monthly projected: \$%.2f\n" "$MONTHLY_PROJECTED"
echo ""
for PLAN PRICE in "Max 5x " $MAX_5X "Max 20x" $MAX_20X; do
    printf "  %s (\$%d/mo): " "$PLAN" "$PRICE"
    VALUE=$(echo "scale=2; $MONTHLY_PROJECTED - $PRICE" | bc)
    if (( $(echo "$VALUE > 0" | bc -l) )); then
        printf "\033[32m+\$%.2f value\033[0m\n" "$VALUE"
    else
        printf "\033[33m\$%.2f under\033[0m\n" "$(echo "$VALUE * -1" | bc)"
    fi
done
echo ""

echo "─── By Model ───"
query "SELECT COALESCE(model, '?'), SUM(cost), COUNT(*) FROM transcripts t $WHERE_CLAUSE GROUP BY model ORDER BY SUM(cost) DESC;" |
    while IFS='|' read -r model cost count; do
        printf "  %s: \$%.2f (%d transcripts)\n" "$model" "$cost" "$count"
    done
echo ""

echo "─── By App ───"
query "SELECT COALESCE(entrypoint, '?'), SUM(cost), COUNT(DISTINCT session_id) FROM transcripts t $WHERE_CLAUSE GROUP BY entrypoint ORDER BY SUM(cost) DESC;" |
    while IFS='|' read -r app cost count; do
        printf "  %s: \$%.2f (%d sessions)\n" "$app" "$cost" "$count"
    done
echo ""

echo "─── Sessions and Agents ───"
query "SELECT kind, SUM(cost), COUNT(*) FROM transcripts t $WHERE_CLAUSE GROUP BY kind ORDER BY kind DESC;" |
    while IFS='|' read -r kind cost count; do
        printf "  %ss: \$%.2f (%d)\n" "$kind" "$cost" "$count"
    done
echo ""

echo "─── By Project ───"
query "SELECT REPLACE(project, RTRIM(project, REPLACE(project, '/', '')), ''), SUM(cost), COUNT(DISTINCT session_id) FROM transcripts t $WHERE_CLAUSE GROUP BY project ORDER BY SUM(cost) DESC LIMIT 10;" |
    while IFS='|' read -r dir cost count; do
        printf "  %s: \$%.2f (%d sessions)\n" "$dir" "$cost" "$count"
    done
echo ""

if [[ "$REPORT_TYPE" == "week" || "$REPORT_TYPE" == "month" || "$REPORT_TYPE" == "all" ]]; then
    echo "─── By Day ───"
    query "SELECT date, SUM(cost), COUNT(DISTINCT session_id) FROM transcripts t $WHERE_CLAUSE GROUP BY date ORDER BY date DESC LIMIT 14;" |
        while IFS='|' read -r date cost count; do
            printf "  %s: \$%.2f (%d sessions)\n" "$date" "$cost" "$count"
        done
    echo ""
fi

echo "─── Recent Sessions (with their agents) ───"
query "SELECT MIN(t.date), COALESCE(NULLIF(MAX(s.session_name), ''), REPLACE(MAX(t.project), RTRIM(MAX(t.project), REPLACE(MAX(t.project), '/', '')), '')), SUM(t.cost)
       FROM transcripts t LEFT JOIN sessions s ON s.session_id = t.session_id $WHERE_CLAUSE
       GROUP BY t.session_id ORDER BY MAX(t.last_at) DESC LIMIT 10;" |
    while IFS='|' read -r date name cost; do
        printf "  %s %s: \$%.2f\n" "$date" "$name" "$cost"
    done
