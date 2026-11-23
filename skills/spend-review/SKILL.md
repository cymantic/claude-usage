---
name: spend-review
description: >-
  Chart Tom's Claude Code spend at API-equivalent rates over the last 30, 14 and 7 days: totals, by day of the week
  and by project, counting every session and agent in the terminal and the desktop app. Use when he runs
  /spend-review or asks what he has spent, where his usage goes, or which projects or days cost most.
---

# Spend review

The figures come from `~/Development/claude-usage/spend-review.py`, which first refreshes `~/.claude/usage.db` from
every transcript on this Mac. They are what the API would have charged, not money spent on a subscription.

1. Run `~/Development/claude-usage/spend-review.py totals` and keep the numbers for the summary.
2. Run `~/Development/claude-usage/spend-review.py weekday`, then chart that result with `mcp__easel__chart`
   (load it with ToolSearch if it is deferred): `x` `day`, `y` `["last_30_days", "last_14_days", "last_7_days"]`,
   `form` `bars`, `unit` `$`, title "Spend by day of week". Leave `data` out so it charts the result as printed.
3. Run `~/Development/claude-usage/spend-review.py project` and chart it the same way with `x` `project`, title "Spend
   by project".
4. Summarise in a few lines: spend and spend per day in each period, the busiest weekday and the costliest project
   over 30 days, and anything that changed between periods (a project that went quiet, a recent rise). Pass on the
   chart tool's `note:` lines. Don't repeat every number the charts show.

Read the figures carefully:

- `Development` is sessions started in `~/Development` itself, mostly in the desktop app; `scratch` is the desktop
  app's scratch folders.
- Days are UTC, so in summer time work just after midnight counts on the day before.
- A model missing from `PRICES` in `usage-sync.py` is not priced; the sync says so on stderr. Add it there.

If `mcp__easel__chart` isn't available, show each table as a Markdown table instead.
