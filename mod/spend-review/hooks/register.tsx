import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Days, Loading, Period, Report } from '../types'

// /spend-review: what Claude Code would have cost at API rates over the last 30, 14 or 7 days, by day of the week
// and by project, in a pane with a button for each period. The figures come from claude-usage's spend-review.py.

const PANE = 'spend-review'
const SCRIPT = '"$HOME/Development/claude-usage/spend-review.py" json'
const PERIODS: Days[] = [30, 14, 7]
const BAR = '█'

const days = atom({ plugin: 'spend-review', key: 'days' } as const, 30 as Days, { shape: 'days-1' })
const report = atom({ plugin: 'spend-review', key: 'report' } as const, null as Report | null, { shape: 'report-1' })
const loading = atom({ plugin: 'spend-review', key: 'loading' } as const, { state: 'loading' } as Loading, {
  shape: 'loading-1',
})

const money = (n: number) => `$${n.toFixed(2)}`

/** A bar `n` of `most` long, in `width` cells; something spent always shows at least one. */
const bar = (n: number, most: number, width: number) =>
  most > 0 && n > 0 ? BAR.repeat(Math.max(1, Math.round((n / most) * width))) : ''

/** Run the script and keep what it reports; the transcripts sync first, which takes a second or two. */
async function refresh($: EngineInterface) {
  await update($, loading, () => ({ state: 'loading' }) as Loading)
  try {
    const { exitCode, stdout, stderr } = await $.process.run(['/bin/sh', '-c', SCRIPT], { timeoutMs: 120_000 })
    if (exitCode !== 0) throw new Error(stderr.trim() || `spend-review.py exited with ${exitCode}`)
    const parsed = JSON.parse(stdout) as Report
    await update($, report, () => parsed)
    await update($, loading, () => ({ state: 'ready' }) as Loading)
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    await update($, loading, () => ({ state: 'failed', error: message }) as Loading)
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'spend-review',
      description: 'Claude Code spend at API rates over 30, 14 or 7 days, by weekday and project',
    })
    return next(e)
  })

  on('command.run', { command: 'spend-review' }, async $ => {
    await $.ui.open({ id: PANE, title: 'Spend review', focus: true })
    await refresh($)
    return { text: 'Spend review opened: 1, 2 and 3 switch between 30, 14 and 7 days, r refreshes.' }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const chosen = await read($, days)
    const data = await read($, report)
    const status = await read($, loading)
    const width = Math.max(10, (e.viewport?.columns ?? 60) - 32)
    const period: Period | undefined = data?.periods[String(chosen)]

    const choose = (d: Days) => () => void update($, days, () => d)

    return (
      <Box flexDirection="column" gap={1}>
        <Box flexDirection="row" gap={1}>
          {PERIODS.map((d, i) => (
            <Button key={`days-${d}`} label={`${d} days`} hotkey={String(i + 1)}
                    variant={d === chosen ? 'primary' : undefined} dimColor={d !== chosen} onPress={choose(d)} />
          ))}
          <Button key="refresh" label="refresh" hotkey="r" dimColor onPress={() => void refresh($)} />
        </Box>

        {status.state === 'loading' && <Text dimColor>Reading transcripts…</Text>}
        {status.state === 'failed' && <Text color="red">Couldn't read spend: {status.error}</Text>}

        {period && (
          <Box flexDirection="column" gap={1}>
            <Text>
              <Text bold>{money(period.totals.spend)}</Text> in {chosen} days, {money(period.totals.per_day)} a day ·{' '}
              {period.totals.sessions} sessions, {period.totals.agents} agents
            </Text>

            <Box flexDirection="column">
              <Text bold>By day of the week</Text>
              {period.weekday.map(row => {
                const most = Math.max(...period.weekday.map(w => w.spend))
                return (
                  <Text key={row.day}>
                    {row.day.padEnd(4)}
                    <Text color="yellow">{bar(row.spend, most, width).padEnd(width)}</Text>{' '}
                    <Text dimColor={row.spend === 0}>{row.spend > 0 ? money(row.spend) : '–'}</Text>
                  </Text>
                )
              })}
            </Box>

            <Box flexDirection="column">
              <Text bold>By project</Text>
              {period.project.length === 0 && <Text dimColor>Nothing spent in this period.</Text>}
              {period.project.map(row => {
                const most = period.project[0]?.spend ?? 0
                const share = period.totals.spend > 0 ? Math.round((row.spend / period.totals.spend) * 100) : 0
                return (
                  <Text key={row.project}>
                    {row.project.slice(0, 16).padEnd(17)}
                    <Text color="yellow">{bar(row.spend, most, width - 13).padEnd(Math.max(0, width - 13))}</Text>{' '}
                    {money(row.spend)} <Text dimColor>{share}%</Text>
                  </Text>
                )
              })}
            </Box>

            <Text dimColor>
              What the API would have charged, to {data?.today}: every session and agent, terminal and desktop app.
            </Text>
          </Box>
        )}
      </Box>
    )
  })
}
