import { expect, test } from 'claude-code/testing'

const PANE = {
  plugin: 'spend-review',
  component: 'Pane',
  requestId: 'spend-review',
  props: {
    title: 'Spend review',
    isFocused: true,
    bodyColumns: 80,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 40 },
    view: {},
  },
} as const

const period = (days: number, spend: number) => ({
  totals: { days, spend, per_day: spend / days, sessions: 2, agents: 1 },
  weekday: ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].map(day => ({ day, spend: day === 'Mon' ? spend : 0 })),
  project: [{ project: 'oh-my-money', spend }],
})

const RUN = {
  command: 'spend-review',
  args: '',
  origin: { kind: 'composer' },
  presentation: { isFullscreen: false, columns: 100 },
} as const

const REPORT = { today: '2026-11-23', periods: { 30: period(30, 300), 14: period(14, 140), 7: period(7, 70) } }

test('the command reads the script and the buttons switch the period', async ($, on) => {
  on('command.register', () => ({ value: { command: 'spend-review' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('process.run', () => ({
    value: { exitCode: 0, stdout: JSON.stringify(REPORT), stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
  }))

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.command.run(RUN)

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /in 30 days/ }))?.text).toContain('$300.00')

  await ui.press({ key: 'days-7' })
  expect((await ui.find({ type: 'Text', text: /in 7 days/ }))?.text).toContain('$70.00 in 7 days, $10.00 a day')
  expect((await ui.find({ type: 'Text', text: /oh-my-money/ }))?.text).toContain('100%')
  await ui.unmount()
})

test('a failing script is shown, not swallowed', async ($, on) => {
  on('command.register', () => ({ value: { command: 'spend-review' } }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('process.run', () => ({
    value: { exitCode: 1, stdout: '', stderr: 'no such table', isStdoutTruncated: false, isStderrTruncated: false },
  }))

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.command.run(RUN)

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /Couldn't read spend/ }))?.text).toContain('no such table')
  await ui.unmount()
})
