import type { UsageRow } from '@/api/types'

export const ROLE_LABEL: Record<string, string> = {
  generator: '出题',
  validator: '复核',
  agent: '学习助手',
  explain: 'AI 解读',
  embedding: '向量',
}

export const SOURCE_LABEL: Record<string, string> = {
  server: '服务端',
  client: '设备',
}

export interface UsageFilter {
  /** Only rows from this many days back (including today); 0 keeps all. */
  days: number
  source: string
  role: string
}

export interface UsageTotals {
  calls: number
  input: number
  output: number
  cached: number
  failures: number
  estimated: number
}

export const emptyTotals = (): UsageTotals => ({ calls: 0, input: 0, output: 0, cached: 0, failures: 0, estimated: 0 })

/** "YYYY-MM-DD" in local time, the way the server labels its days. */
export function dayKey(d: Date): string {
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

/** The earliest day label that is still inside the last [days] days (today counts as the first). */
export function firstDay(days: number, now: Date): string {
  const d = new Date(now.getFullYear(), now.getMonth(), now.getDate() - (days - 1))
  return dayKey(d)
}

export function filterRows(rows: UsageRow[], f: UsageFilter, now: Date): UsageRow[] {
  const from = f.days > 0 ? firstDay(f.days, now) : ''
  return rows.filter((r) => (!from || r.day >= from) && (!f.source || r.source === f.source) && (!f.role || r.role === f.role))
}

export function totalsOf(rows: UsageRow[]): UsageTotals {
  return rows.reduce((a, r) => {
    a.calls += r.calls
    a.input += r.input_tokens
    a.output += r.output_tokens
    a.cached += r.cached_tokens
    a.failures += r.failures
    a.estimated += r.estimated_calls
    return a
  }, emptyTotals())
}

/** Tokens spent (input + output) today and so far this calendar month. */
export function todayAndMonth(rows: UsageRow[], now: Date): { today: number; month: number } {
  const today = dayKey(now)
  const month = today.slice(0, 7)
  let t = 0
  let m = 0
  for (const r of rows) {
    const n = r.input_tokens + r.output_tokens
    if (r.day === today) t += n
    if (r.day.startsWith(month)) m += n
  }
  return { today: t, month: m }
}

/** Share of input served from the provider's cache, 0-100. */
export function cacheRate(t: UsageTotals): number {
  const denom = t.input + t.cached
  return denom ? Math.round((t.cached / denom) * 100) : 0
}
