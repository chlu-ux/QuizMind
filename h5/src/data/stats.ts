import type { LocalQuestion, LocalAttempt } from './types'

/** Attempts that took longer than this (a page left open) count as this long in the study-time total. */
const MAX_ATTEMPT_MS = 2 * 60 * 1000

export interface Tally {
  attempts: number
  correct: number
}

export interface GroupStat extends Tally {
  key: string
  label: string
}

export interface DayStat extends Tally {
  /** Local calendar day, "M/D". */
  label: string
}

export interface WeakQuestion {
  question: LocalQuestion
  attempts: number
  wrong: number
}

export interface BankReport {
  totalQuestions: number
  /** Distinct questions answered at least once. */
  answeredQuestions: number
  /** Questions whose most recent attempt was right. */
  latestCorrect: number
  wrongBook: number
  attempts: number
  correct: number
  /** Share of all attempts that were right, 0-100; null before the first attempt. */
  accuracy: number | null
  studyMs: number
  /** Consecutive days with at least one attempt, counting back from today (or yesterday if nothing yet today). */
  streakDays: number
  /** The last 7 days, oldest first. */
  daily: DayStat[]
  byType: GroupStat[]
  byDifficulty: GroupStat[]
  /** Knowledge points, weakest first. */
  byTag: GroupStat[]
  /** Questions missed most, worst first. */
  weakest: WeakQuestion[]
}

export const percent = (t: Tally): number | null => (t.attempts ? Math.round((t.correct * 100) / t.attempts) : null)

function dayStart(t: number): number {
  const d = new Date(t)
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
}

/** Start of the day [offset] days before the day of [t], in local time (DST-safe). */
function dayStartBefore(t: number, offset: number): number {
  const d = new Date(t)
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() - offset).getTime()
}

function add(t: Tally, correct: boolean) {
  t.attempts++
  if (correct) t.correct++
}

function groups(map: Map<string, GroupStat>, key: string, label: string, correct: boolean) {
  let g = map.get(key)
  if (!g) map.set(key, (g = { key, label, attempts: 0, correct: 0 }))
  add(g, correct)
}

/**
 * Summarises how a bank has been practised. [questions] are the bank's visible
 * questions; attempts for anything else (withdrawn questions, other banks) are ignored.
 * [wrongIds] are the ids currently in the wrong book.
 */
export function buildReport(
  questions: LocalQuestion[],
  attempts: LocalAttempt[],
  wrongIds: Set<string>,
  now: number,
): BankReport {
  const byId = new Map(questions.map((q) => [q.id, q]))
  const mine = attempts.filter((a) => byId.has(a.question_id)).sort((a, b) => a.answered_at - b.answered_at)

  const total: Tally = { attempts: 0, correct: 0 }
  const latest = new Map<string, boolean>()
  const perQuestion = new Map<string, Tally>()
  const types = new Map<string, GroupStat>()
  const difficulties = new Map<string, GroupStat>()
  const tags = new Map<string, GroupStat>()
  const days = new Set<number>()
  let studyMs = 0

  const today = dayStart(now)
  const daily: (DayStat & { start: number })[] = []
  for (let i = 6; i >= 0; i--) {
    const start = dayStartBefore(now, i)
    const d = new Date(start)
    daily.push({ start, label: `${d.getMonth() + 1}/${d.getDate()}`, attempts: 0, correct: 0 })
  }

  for (const a of mine) {
    const q = byId.get(a.question_id)!
    add(total, a.is_correct)
    latest.set(a.question_id, a.is_correct)
    let pq = perQuestion.get(q.id)
    if (!pq) perQuestion.set(q.id, (pq = { attempts: 0, correct: 0 }))
    add(pq, a.is_correct)
    groups(types, q.type, q.type === 'judge' ? '判断题' : '单选题', a.is_correct)
    groups(difficulties, String(q.difficulty), `难度 ${q.difficulty}`, a.is_correct)
    for (const tag of q.tags) groups(tags, tag, tag, a.is_correct)
    studyMs += Math.min(Math.max(a.duration_ms ?? 0, 0), MAX_ATTEMPT_MS)

    const day = dayStart(a.answered_at)
    days.add(day)
    const bucket = daily.find((d) => d.start === day)
    if (bucket) add(bucket, a.is_correct)
  }

  let streakDays = 0
  // A streak is still alive if today has no attempt yet but yesterday did.
  let cursor = days.has(today) ? 0 : 1
  while (days.has(dayStartBefore(now, cursor))) {
    streakDays++
    cursor++
  }

  const weakest: WeakQuestion[] = []
  for (const [id, t] of perQuestion) {
    if (t.attempts - t.correct > 0) {
      weakest.push({ question: byId.get(id)!, attempts: t.attempts, wrong: t.attempts - t.correct })
    }
  }
  weakest.sort((a, b) => b.wrong / b.attempts - a.wrong / a.attempts || b.wrong - a.wrong || a.question.id.localeCompare(b.question.id))

  const rate = (g: GroupStat) => g.correct / g.attempts
  return {
    totalQuestions: questions.length,
    answeredQuestions: perQuestion.size,
    latestCorrect: [...latest.values()].filter(Boolean).length,
    wrongBook: questions.filter((q) => wrongIds.has(q.id)).length,
    attempts: total.attempts,
    correct: total.correct,
    accuracy: percent(total),
    studyMs,
    streakDays,
    daily: daily.map(({ label, attempts, correct }) => ({ label, attempts, correct })),
    byType: [...types.values()].sort((a, b) => a.key.localeCompare(b.key)),
    byDifficulty: [...difficulties.values()].sort((a, b) => Number(a.key) - Number(b.key)),
    byTag: [...tags.values()].sort((a, b) => rate(a) - rate(b) || b.attempts - a.attempts || a.label.localeCompare(b.label, 'zh')),
    weakest,
  }
}

/** "1 小时 5 分" / "12 分钟" / "不到 1 分钟". */
export function formatDuration(ms: number): string {
  const minutes = Math.floor(ms / 60000)
  if (minutes < 1) return '不到 1 分钟'
  if (minutes < 60) return `${minutes} 分钟`
  const h = Math.floor(minutes / 60)
  const m = minutes % 60
  return m ? `${h} 小时 ${m} 分` : `${h} 小时`
}
