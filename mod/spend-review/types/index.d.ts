export type Days = 30 | 14 | 7

export type Period = {
  totals: { days: number; spend: number; per_day: number; sessions: number; agents: number }
  weekday: { day: string; spend: number }[]
  project: { project: string; spend: number }[]
}

export type Report = { today: string; periods: Record<string, Period> }

/** Where the report is: being read, read, or failed with the script's error. */
export type Loading = { state: 'loading' } | { state: 'ready' } | { state: 'failed'; error: string }

declare module 'claude-code' {
  interface PluginState {
    'spend-review': { days: Shaped<Days>; report: Shaped<Report | null>; loading: Shaped<Loading> }
  }
}
