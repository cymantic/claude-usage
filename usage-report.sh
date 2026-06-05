#!/bin/zsh

# Claude Code Usage Report
# Reads ~/.claude/usage.db (SQLite) and aggregates costs/usage

DB_FILE="$HOME/.claude/usage.db"

if [[ ! -f "$DB_FILE" ]]; then
    echo "No usage database found at $DB_FILE"
    echo "The database will be created after your first Claude Code session."
    exit 1
fi

# Default to today if no args
REPORT_TYPE="${1:-today}"

case "$REPORT_TYPE" in
    dump|raw)
        sqlite3 -header -csv "$DB_FILE" "SELECT * FROM sessions ORDER BY updated_at DESC;"
        exit 0
        ;;
    today)
        DATE_FILTER=$(date -u +"%Y-%m-%d")
        WHERE_CLAUSE="WHERE date = '$DATE_FILTER'"
        TITLE="Today's Usage ($DATE_FILTER)"
        DAYS_IN_PERIOD=1
        ;;
    yesterday)
        DATE_FILTER=$(date -u -v-1d +"%Y-%m-%d")
        WHERE_CLAUSE="WHERE date = '$DATE_FILTER'"
        TITLE="Yesterday's Usage ($DATE_FILTER)"
        DAYS_IN_PERIOD=1
        ;;
    week)
        DATE_FILTER=$(date -u -v-7d +"%Y-%m-%d")
        WHERE_CLAUSE="WHERE date >= '$DATE_FILTER'"
        TITLE="Last 7 Days Usage (since $DATE_FILTER)"
        DAYS_IN_PERIOD=7
        ;;
    month)
        DATE_FILTER=$(date -u -v-30d +"%Y-%m-%d")
        WHERE_CLAUSE="WHERE date >= '$DATE_FILTER'"
        TITLE="Last 30 Days Usage (since $DATE_FILTER)"
        DAYS_IN_PERIOD=30
        ;;
    all)
        WHERE_CLAUSE=""
        TITLE="All Time Usage"
        DAYS_IN_PERIOD=$(sqlite3 "$DB_FILE" "SELECT CAST(julianday('now') - julianday(MIN(date)) AS INTEGER) + 1 FROM sessions;")
        [[ $DAYS_IN_PERIOD -lt 1 ]] && DAYS_IN_PERIOD=1
        ;;
    *)
        # Assume it's a specific date
        DATE_FILTER="$1"
        WHERE_CLAUSE="WHERE date = '$DATE_FILTER'"
        TITLE="Usage for $DATE_FILTER"
        DAYS_IN_PERIOD=1
        ;;
esac

echo "═══════════════════════════════════════════════════════════"
echo " $TITLE"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Show current rate limits if available
RATE_FILE="$HOME/.claude/rate-limits.json"
if [[ -f "$RATE_FILE" ]]; then
    RATE_5H=$(jq -r '.rate_limit_5h // empty' "$RATE_FILE")
    RATE_7D=$(jq -r '.rate_limit_7d // empty' "$RATE_FILE")
    RATE_TS=$(jq -r '.timestamp // empty' "$RATE_FILE")

    if [[ -n "$RATE_5H" ]]; then
        echo "─── Current Max Plan Usage ───"
        printf "  5-hour limit:  %5.1f%% used\n" "$RATE_5H"
        if [[ -n "$RATE_7D" && "$RATE_7D" != "null" ]]; then
            printf "  7-day limit:   %5.1f%% used\n" "$RATE_7D"
        fi
        echo "  (as of $RATE_TS)"
        echo ""
    fi
fi

# Get totals
read TOTAL_COST TOTAL_SESSIONS TOTAL_TOKENS_IN TOTAL_TOKENS_OUT <<< $(sqlite3 -separator ' ' "$DB_FILE" \
    "SELECT COALESCE(SUM(cost), 0), COUNT(*), COALESCE(SUM(tokens_in), 0), COALESCE(SUM(tokens_out), 0) FROM sessions $WHERE_CLAUSE;")

printf "Total Cost:      \$%.2f (API equivalent)\n" "$TOTAL_COST"
printf "Total Sessions:  %d\n" "$TOTAL_SESSIONS"
printf "Tokens In:       %'d\n" "$TOTAL_TOKENS_IN"
printf "Tokens Out:      %'d\n" "$TOTAL_TOKENS_OUT"
echo ""

# Max plan ROI calculation
echo "─── Max Plan Value ───"
MAX_5X=100
MAX_20X=200

# Project to monthly
if [[ $DAYS_IN_PERIOD -gt 0 ]]; then
    MONTHLY_PROJECTED=$(echo "scale=2; $TOTAL_COST * 30 / $DAYS_IN_PERIOD" | bc)
else
    MONTHLY_PROJECTED=$TOTAL_COST
fi

printf "  Period:            %d days\n" "$DAYS_IN_PERIOD"
printf "  Monthly projected: \$%.2f\n" "$MONTHLY_PROJECTED"
echo ""
printf "  Max 5x  (\$100/mo): "
SAVINGS_5X=$(echo "scale=2; $MONTHLY_PROJECTED - $MAX_5X" | bc)
if (( $(echo "$SAVINGS_5X > 0" | bc -l) )); then
    printf "\033[32m+\$%.2f value\033[0m\n" "$SAVINGS_5X"
else
    printf "\033[33m\$%.2f under\033[0m\n" "$(echo "$SAVINGS_5X * -1" | bc)"
fi

printf "  Max 20x (\$200/mo): "
SAVINGS_20X=$(echo "scale=2; $MONTHLY_PROJECTED - $MAX_20X" | bc)
if (( $(echo "$SAVINGS_20X > 0" | bc -l) )); then
    printf "\033[32m+\$%.2f value\033[0m\n" "$SAVINGS_20X"
else
    printf "\033[33m\$%.2f under\033[0m\n" "$(echo "$SAVINGS_20X * -1" | bc)"
fi
echo ""

# By model
echo "─── By Model ───"
sqlite3 -separator '|' "$DB_FILE" \
    "SELECT model, SUM(cost), COUNT(*) FROM sessions $WHERE_CLAUSE GROUP BY model ORDER BY SUM(cost) DESC;" | \
    while IFS='|' read -r model cost count; do
        printf "  %s: \$%.2f (%d sessions)\n" "$model" "$cost" "$count"
    done
echo ""

# By directory (project)
echo "─── By Project ───"
sqlite3 -separator '|' "$DB_FILE" \
    "SELECT REPLACE(directory, RTRIM(directory, REPLACE(directory, '/', '')), ''), SUM(cost), COUNT(*) FROM sessions $WHERE_CLAUSE GROUP BY directory ORDER BY SUM(cost) DESC LIMIT 10;" | \
    while IFS='|' read -r dir cost count; do
        printf "  %s: \$%.2f (%d sessions)\n" "$dir" "$cost" "$count"
    done
echo ""

# By day (if looking at more than one day)
if [[ "$REPORT_TYPE" == "week" || "$REPORT_TYPE" == "month" || "$REPORT_TYPE" == "all" ]]; then
    echo "─── By Day ───"
    sqlite3 -separator '|' "$DB_FILE" \
        "SELECT date, SUM(cost), COUNT(*) FROM sessions $WHERE_CLAUSE GROUP BY date ORDER BY date DESC LIMIT 14;" | \
        while IFS='|' read -r date cost count; do
            printf "  %s: \$%.2f (%d sessions)\n" "$date" "$cost" "$count"
        done
    echo ""
fi

# Recent sessions with names
echo "─── Recent Sessions ───"
sqlite3 -separator '|' "$DB_FILE" \
    "SELECT date, COALESCE(NULLIF(session_name, ''), REPLACE(directory, RTRIM(directory, REPLACE(directory, '/', '')), '')), cost FROM sessions $WHERE_CLAUSE ORDER BY updated_at DESC LIMIT 10;" | \
    while IFS='|' read -r date name cost; do
        printf "  %s %s: \$%.2f\n" "$date" "$name" "$cost"
    done
