import { tagLabeler } from './tags'
import type { ExamRecord, LocalAttempt, LocalQuestion } from './types'

/** An answer that took longer than this (a page left open) counts as this long in the practice-time total. */
const MAX_ATTEMPT_MS = 2 * 60 * 1000
/** Likewise for the time spent reading after an answer (explanations are read for longer than questions). */
const MAX_REVIEW_MS = 3 * 60 * 1000

export interface Tally {
  attempts: number
  correct: number
}

export interface GroupStat extends Tally {
  key: string
  label: string
}

/** Time split the way the stats show it: answering, reading after answering. */
export interface Spent {
  /** Time from showing a question to answering it. */
  practiceMs: number
  /** Time spent on a question after answering it (explanation). */
  reviewMs: number
}

export interface DayStat extends Tally, Spent {
  /** Local calendar day, "M/D". */
  label: string
}

/** A question that keeps going wrong. [attempts] and [wrong] cover only its most recent answers. */
export interface WeakQuestion {
  question: LocalQuestion
  attempts: number
  wrong: number
}

export interface ExamPoint {
  finishedAt: number
  percent: number
  passed: boolean
}

/** How many of a question's latest answers decide whether it is "weak". */
const WEAK_WINDOW = 5
/** Weak ranking pulls small samples toward this error rate, with the weight of this many answers. */
const WEAK_PRIOR_RATE = 0.25
const WEAK_PRIOR_WEIGHT = 4

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
  /** Time spent answering questions. */
  practiceMs: number
  /** Time spent reading explanations after answering. */
  reviewMs: number
  /** Practice plus review: everything spent studying. */
  studyMs: number
  /** Consecutive days with at least one attempt, counting back from today (or yesterday if nothing yet today). */
  streakDays: number
  /** The last 7 days, oldest first. */
  daily: DayStat[]
  /** The last 30 days, oldest first. */
  daily30: DayStat[]
  /** Finished exams, oldest first (the latest 20). */
  examTrend: ExamPoint[]
  byType: GroupStat[]
  byDifficulty: GroupStat[]
  /** Knowledge points as tagged (spelling variants folded), weakest first. */
  byTag: GroupStat[]
  /** Knowledge points with related tags merged ("UML 辨析" into "UML"), weakest first. */
  byTagMerged: GroupStat[]
  /** Questions that went wrong lately, worst first. */
  weakest: WeakQuestion[]
}

export const percent = (t: Tally): number | null => (t.attempts ? Math.round((t.correct * 100) / t.attempts) : null)

/** Time an answer counts for in the study totals: answering and reading afterwards, each capped. */
export function attemptTimes(a: Pick<LocalAttempt, 'duration_ms' | 'review_ms'>): Spent {
  return {
    practiceMs: Math.min(Math.max(a.duration_ms ?? 0, 0), MAX_ATTEMPT_MS),
    reviewMs: Math.min(Math.max(a.review_ms ?? 0, 0), MAX_REVIEW_MS),
  }
}

/** Midnight at the start of the local day of [t]. */
export function dayStart(t: number): number {
  const d = new Date(t)
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
}

/** Start of the day [offset] days before the day of [t], in local time (DST-safe). */
export function dayStartBefore(t: number, offset: number): number {
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
  exams: ExamRecord[] = [],
): BankReport {
  const byId = new Map(questions.map((q) => [q.id, q]))
  const mine = attempts.filter((a) => byId.has(a.question_id)).sort((a, b) => a.answered_at - b.answered_at)

  const total: Tally = { attempts: 0, correct: 0 }
  const latest = new Map<string, boolean>()
  const perQuestion = new Map<string, Tally>()
  const types = new Map<string, GroupStat>()
  const difficulties = new Map<string, GroupStat>()
  const tags = new Map<string, GroupStat>()
  const mergedTags = new Map<string, GroupStat>()
  const fold = tagLabeler(questions.flatMap((q) => q.tags), false)
  const merge = tagLabeler(questions.flatMap((q) => q.tags), true)
  const recent = new Map<string, boolean[]>() // each question's results, oldest first
  const days = new Set<number>()
  let practiceMs = 0
  let reviewMs = 0

  const today = dayStart(now)
  const daily: (DayStat & { start: number })[] = []
  for (let i = 29; i >= 0; i--) {
    const start = dayStartBefore(now, i)
    const d = new Date(start)
    daily.push({ start, label: `${d.getMonth() + 1}/${d.getDate()}`, attempts: 0, correct: 0, practiceMs: 0, reviewMs: 0 })
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
    for (const tag of new Set(q.tags.map(fold))) groups(tags, tag.toLowerCase(), tag, a.is_correct)
    for (const tag of new Set(q.tags.map(merge))) groups(mergedTags, tag.toLowerCase(), tag, a.is_correct)
    const results = recent.get(q.id) ?? []
    results.push(a.is_correct)
    recent.set(q.id, results)
    const { practiceMs: practice, reviewMs: review } = attemptTimes(a)
    practiceMs += practice
    reviewMs += review

    const day = dayStart(a.answered_at)
    days.add(day)
    const bucket = daily.find((d) => d.start === day)
    if (bucket) {
      add(bucket, a.is_correct)
      bucket.practiceMs += practice
      bucket.reviewMs += review
    }
  }

  let streakDays = 0
  // A streak is still alive if today has no attempt yet but yesterday did.
  let cursor = days.has(today) ? 0 : 1
  while (days.has(dayStartBefore(now, cursor))) {
    streakDays++
    cursor++
  }

  // Rank by the error rate over the latest answers, pulled toward a prior so that a
  // single miss does not outrank a question missed 3 times in 5.
  const weakest: (WeakQuestion & { score: number })[] = []
  for (const [id, results] of recent) {
    const last = results.slice(-WEAK_WINDOW)
    const wrong = last.filter((ok) => !ok).length
    if (wrong === 0) continue
    const score = (wrong + WEAK_PRIOR_RATE * WEAK_PRIOR_WEIGHT) / (last.length + WEAK_PRIOR_WEIGHT)
    weakest.push({ question: byId.get(id)!, attempts: last.length, wrong, score })
  }
  weakest.sort((a, b) => b.score - a.score || b.wrong - a.wrong || a.question.id.localeCompare(b.question.id))

  const rate = (g: GroupStat) => g.correct / g.attempts
  const byRate = (a: GroupStat, b: GroupStat) =>
    rate(a) - rate(b) || b.attempts - a.attempts || a.label.localeCompare(b.label, 'zh')
  return {
    totalQuestions: questions.length,
    answeredQuestions: perQuestion.size,
    latestCorrect: [...latest.values()].filter(Boolean).length,
    wrongBook: questions.filter((q) => wrongIds.has(q.id)).length,
    attempts: total.attempts,
    correct: total.correct,
    accuracy: percent(total),
    practiceMs,
    reviewMs,
    studyMs: practiceMs + reviewMs,
    streakDays,
    daily: daily.slice(-7).map(({ start: _s, ...day }) => day),
    daily30: daily.map(({ start: _s, ...day }) => day),
    examTrend: [...exams]
      .sort((a, b) => a.finished_at - b.finished_at)
      .slice(-20)
      .map((e) => ({ finishedAt: e.finished_at, percent: e.percent, passed: e.passed })),
    byType: [...types.values()].sort((a, b) => a.key.localeCompare(b.key)),
    byDifficulty: [...difficulties.values()].sort((a, b) => Number(a.key) - Number(b.key)),
    byTag: [...tags.values()].sort(byRate),
    byTagMerged: [...mergedTags.values()].sort(byRate),
    weakest: weakest.map(({ question, attempts, wrong }) => ({ question, attempts, wrong })),
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

/** The same as [formatDuration], split into number and unit for a big figure: "1"+"小时", "5"+"分". */
export function durationParts(ms: number): { v: string; u: string }[] {
  const minutes = Math.floor(ms / 60000)
  if (minutes < 1) return [{ v: ms > 0 ? '<1' : '0', u: '分钟' }]
  if (minutes < 60) return [{ v: String(minutes), u: '分钟' }]
  const h = Math.floor(minutes / 60)
  const m = minutes % 60
  return m ? [{ v: String(h), u: '小时' }, { v: String(m), u: '分' }] : [{ v: String(h), u: '小时' }]
}

/** Minutes only, for the label over a day's bar: "12 分" / "<1 分". */
export function formatMinutes(ms: number): string {
  if (ms <= 0) return ''
  const m = Math.round(ms / 60000)
  return m < 1 ? '<1分' : `${m}分`
}
