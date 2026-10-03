import { newUlid } from '@/core/ulid'
import { isCorrect } from '@/data/progress'
import type { QuestionHistory, Repo } from '@/data/repo'
import { tagLabeler } from '@/data/tags'
import type { ExamDraft, ExamRecord, LocalQuestion } from '@/data/types'
import { optionOrder, seededRng } from './session'

/** Score needed to pass a mock exam, in percent. */
export const PASS_PERCENT = 60

/** Question counts offered for a bank with [available] questions; the last choice is always "all of them". */
export function examCountChoices(available: number): number[] {
  const presets = [10, 20, 50, 100].filter((n) => n < available)
  return [...presets, available]
}

function shuffled<T>(items: T[], rng: () => number): T[] {
  const pool = [...items]
  for (let i = pool.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1))
    ;[pool[i], pool[j]] = [pool[j], pool[i]]
  }
  return pool
}

/** [count] distinct questions picked at random. */
export function drawExam(qs: LocalQuestion[], count: number, rng: () => number = Math.random): LocalQuestion[] {
  return shuffled(qs, rng).slice(0, Math.max(0, Math.min(count, qs.length)))
}

/**
 * How the paper is put together:
 *  - random: any questions
 *  - weak: questions you got wrong last time first, then ones never tried, then the rest
 *  - balanced: easy / medium / hard in a 4 : 4 : 2 mix
 */
export type PaperStrategy = 'random' | 'weak' | 'balanced'

export const STRATEGIES: { value: PaperStrategy; label: string; hint: string }[] = [
  { value: 'random', label: '随机', hint: '从题库随机抽题' },
  { value: 'weak', label: '查漏补缺', hint: '优先抽上次做错的和没做过的题' },
  { value: 'balanced', label: '难度均衡', hint: '简单、中等、困难按 4 : 4 : 2 搭配' },
]

export interface PaperOptions {
  strategy: PaperStrategy
  /** Knowledge-point labels (see [paperTags]); empty = every question. */
  tags?: string[]
  /** Needed by 'weak'. */
  history?: Map<string, QuestionHistory>
  wrongIds?: Set<string>
}

/** Knowledge points a paper can be limited to, biggest first, with how many questions carry each. */
export function paperTags(qs: LocalQuestion[]): { label: string; count: number }[] {
  const label = tagLabeler(qs.flatMap((q) => q.tags), true)
  const counts = new Map<string, number>()
  for (const q of qs) for (const t of new Set(q.tags.map(label))) counts.set(t, (counts.get(t) ?? 0) + 1)
  return [...counts.entries()]
    .map(([l, count]) => ({ label: l, count }))
    .sort((a, b) => b.count - a.count || a.label.localeCompare(b.label, 'zh'))
}

/** The questions a paper may draw from: those carrying one of [tags], or all when none are given. */
export function paperPool(qs: LocalQuestion[], tags: string[] = []): LocalQuestion[] {
  if (tags.length === 0) return qs
  const label = tagLabeler(qs.flatMap((q) => q.tags), true)
  const wanted = new Set(tags)
  return qs.filter((q) => q.tags.some((t) => wanted.has(label(t))))
}

const bucketOf = (q: LocalQuestion) => (q.difficulty <= 2 ? 0 : q.difficulty === 3 ? 1 : 2)
const BALANCE = [0.4, 0.4, 0.2]

/** Picks [count] questions for a paper. The result is in random order. */
export function drawPaper(
  qs: LocalQuestion[],
  count: number,
  opts: PaperOptions,
  rng: () => number = Math.random,
): LocalQuestion[] {
  const pool = paperPool(qs, opts.tags)
  const n = Math.max(0, Math.min(count, pool.length))
  let picked: LocalQuestion[]

  if (opts.strategy === 'weak') {
    const tier = (q: LocalQuestion) => {
      const h = opts.history?.get(q.id)
      if (opts.wrongIds?.has(q.id) || (h && !h.lastCorrect)) return 0
      return h ? 2 : 1
    }
    picked = [0, 1, 2].flatMap((t) => shuffled(pool.filter((q) => tier(q) === t), rng)).slice(0, n)
  } else if (opts.strategy === 'balanced') {
    const buckets = [0, 1, 2].map((b) => shuffled(pool.filter((q) => bucketOf(q) === b), rng))
    picked = buckets.flatMap((list, b) => list.splice(0, Math.round(n * BALANCE[b])))
    // A bucket that ran dry (or rounding) is made up from whatever is left.
    picked = picked.slice(0, n)
    if (picked.length < n) picked.push(...shuffled(buckets.flat(), rng).slice(0, n - picked.length))
  } else {
    picked = shuffled(pool, rng).slice(0, n)
  }
  return shuffled(picked, rng)
}

/** One question of a graded paper. */
export interface ExamEntry {
  id: string
  /** Null when the question has since been withdrawn. */
  question: LocalQuestion | null
  /** Original option indexes picked; empty when left blank. */
  selected: number[]
  correct: boolean
}

export interface ExamResult extends ExamRecord {
  entries: ExamEntry[]
}

/** Pairs a stored exam with the questions that are still around. */
export function examEntries(record: ExamRecord, questions: Map<string, LocalQuestion>): ExamEntry[] {
  return record.items.map((it) => ({ id: it.q, question: questions.get(it.q) ?? null, selected: it.s, correct: it.c }))
}

/**
 * A mock exam: a fixed list of questions answered with no feedback, answers
 * changeable until the whole paper is handed in (by the learner, or when the
 * time runs out). Only then is anything graded and written to the attempt log,
 * so a half-finished exam leaves no trace in the statistics.
 *
 * Progress is kept on the device after every change ([ExamDraft]), so a reload
 * or a killed app can [restore] it. The countdown runs from the start time, so
 * being away does not stop the clock.
 *
 * As in QuizSession, everything stored or graded uses original option indexes;
 * only `displayOptions` and `selectAt` know about the shuffled positions.
 */
export class ExamSession {
  index = 0
  result: ExamResult | null = null
  busy = false
  private chosen: number[][]
  private spent: number[]
  private marks: boolean[]
  private orders: number[][]
  private enteredAt: number
  private inFlight: Promise<ExamResult> | null = null
  private readonly startedAt: number
  readonly seed: number
  private readonly slots: number[]

  constructor(
    readonly bankId: string,
    readonly title: string,
    readonly questions: LocalQuestion[],
    private readonly repo: Repo,
    /** Time allowed in seconds, null for none. */
    readonly limitSec: number | null,
    private readonly clock: () => number = Date.now,
    seed?: number,
    /** Set when resuming: the original start, plus what was already answered. */
    resume?: { startedAt: number; index: number; chosen: number[][]; spent: number[]; marks: boolean[]; slots: number[] },
  ) {
    if (questions.length === 0) throw new Error('an exam needs at least one question')
    this.seed = seed ?? Math.floor(Math.random() * 2 ** 30)
    this.enteredAt = clock()
    this.startedAt = resume?.startedAt ?? this.enteredAt
    this.slots = resume?.slots ?? questions.map((_, i) => i)
    this.index = resume?.index ?? 0
    this.chosen = resume?.chosen ?? questions.map(() => [])
    this.spent = resume?.spent ?? questions.map(() => 0)
    this.marks = resume?.marks ?? questions.map(() => false)
    this.orders = questions.map((q, i) => optionOrder(q, seededRng(this.seed + this.slots[i] * 7919)))
  }

  /**
   * Picks an exam up from its saved [draft]. [available] holds the questions that still
   * exist; withdrawn ones are dropped from the paper. Null when none are left.
   */
  static restore(
    draft: ExamDraft,
    available: LocalQuestion[],
    repo: Repo,
    clock: () => number = Date.now,
  ): ExamSession | null {
    const byId = new Map(available.map((q) => [q.id, q]))
    const keep = draft.ids.map((id, i) => ({ id, i })).filter(({ id }) => byId.has(id))
    if (keep.length === 0) return null
    const marked = new Set(draft.marked)
    // Back to the question that was open, or the next one still around if it was withdrawn.
    const at = keep.findIndex(({ i }) => i >= draft.index)
    return new ExamSession(
      draft.bank_id,
      draft.title,
      keep.map(({ id }) => byId.get(id)!),
      repo,
      draft.limit_sec,
      clock,
      draft.seed,
      {
        startedAt: draft.started_at,
        index: at >= 0 ? at : keep.length - 1,
        chosen: keep.map(({ id }) => [...(draft.answers[id] ?? [])]),
        spent: keep.map(({ id }) => draft.spent[id] ?? 0),
        marks: keep.map(({ id }) => marked.has(id)),
        slots: keep.map(({ i }) => draft.slots?.[i] ?? i),
      },
    )
  }

  get length() {
    return this.questions.length
  }
  get current() {
    return this.questions[this.index]
  }
  get selected() {
    return this.chosen[this.index]
  }
  get submitted() {
    return this.result !== null
  }
  get answeredCount() {
    return this.chosen.filter((c) => c.length > 0).length
  }
  isAnswered(i: number) {
    return this.chosen[i].length > 0
  }
  get markedCount() {
    return this.marks.filter(Boolean).length
  }
  isMarked(i: number) {
    return this.marks[i]
  }
  /** Whether more can still change: false once handing in has begun. */
  private get open() {
    return !this.submitted && !this.busy
  }

  /** Seconds left at time [at], never below 0; null for an untimed exam. */
  remainingSec(at: number = this.clock()): number | null {
    if (this.limitSec === null) return null
    return Math.max(0, Math.ceil(this.limitSec - (at - this.startedAt) / 1000))
  }

  get displayOptions(): { text: string; original: number }[] {
    return this.orders[this.index].map((original) => ({ text: this.current.options[original], original }))
  }

  labelOf(original: number): string {
    const position = this.orders[this.index].indexOf(original)
    return this.current.type === 'judge' ? String(position + 1) : String.fromCharCode(65 + position)
  }

  select(option: number) {
    if (!this.open || option < 0 || option >= this.current.options.length) return
    this.chosen[this.index] = [option]
    this.save()
  }

  selectAt(position: number) {
    const original = this.orders[this.index][position]
    if (original !== undefined) this.select(original)
  }

  /** Flags the current question "check again", or clears the flag. */
  toggleMark() {
    if (!this.open) return
    this.marks[this.index] = !this.marks[this.index]
    this.save()
  }

  /** Moves to question [i], crediting the time spent on the one being left. */
  go(i: number) {
    if (!this.open || i < 0 || i >= this.length || i === this.index) return
    this.leave()
    this.index = i
    this.save()
  }
  next() {
    this.go(this.index + 1)
  }
  previous() {
    this.go(this.index - 1)
  }

  private leave() {
    const now = this.clock()
    this.spent[this.index] += Math.max(now - this.enteredAt, 0)
    this.enteredAt = now
  }

  /** What is needed to pick this exam up again later. */
  snapshot(): ExamDraft {
    const now = this.clock()
    const answers: Record<string, number[]> = {}
    const spent: Record<string, number> = {}
    this.questions.forEach((q, i) => {
      if (this.chosen[i].length > 0) answers[q.id] = [...this.chosen[i]]
      spent[q.id] = this.spent[i] + (i === this.index ? Math.max(now - this.enteredAt, 0) : 0)
    })
    return {
      bank_id: this.bankId,
      title: this.title,
      ids: this.questions.map((q) => q.id),
      slots: [...this.slots],
      seed: this.seed,
      started_at: this.startedAt,
      limit_sec: this.limitSec,
      index: this.index,
      answers,
      spent,
      marked: this.questions.filter((_, i) => this.marks[i]).map((q) => q.id),
      saved_at: now,
    }
  }

  /** Stores progress on this device. Fire and forget: a failure only costs the ability to resume. */
  save() {
    if (!this.open) return
    this.repo.saveExamDraft(this.snapshot()).catch(() => {})
  }

  /** Grades the paper and records every answered question. Calling it again, e.g. when the timeout races the button, returns the same result. */
  submit(): Promise<ExamResult> {
    this.inFlight ??= this.grade().finally(() => {
      this.inFlight = null
    })
    return this.inFlight
  }

  private async grade(): Promise<ExamResult> {
    if (this.result) return this.result
    this.busy = true
    try {
      this.leave()
      const finishedAt = this.clock()
      const entries: ExamEntry[] = this.questions.map((question, i) => {
        const selected = [...this.chosen[i]]
        return { id: question.id, question, selected, correct: selected.length > 0 && isCorrect(selected, question.answer) }
      })
      const correct = entries.filter((e) => e.correct).length
      const pct = Math.round((correct * 100) / this.length)
      const wall = Math.max(finishedAt - this.startedAt, 0)
      // A timed exam runs on the wall clock; an untimed one counts only time spent on questions.
      const used =
        this.limitSec === null ? this.spent.reduce((a, b) => a + b, 0) : Math.min(wall, this.limitSec * 1000)
      const record: ExamRecord = {
        id: newUlid(finishedAt),
        bank_id: this.bankId,
        title: this.title,
        finished_at: finishedAt,
        total: this.length,
        correct,
        answered: this.answeredCount,
        percent: pct,
        passed: pct >= PASS_PERCENT,
        limit_sec: this.limitSec,
        used_ms: used,
        device_id: this.repo.deviceId,
        items: entries.map((e) => ({ q: e.id, s: e.selected, c: e.correct })),
      }
      const answers = entries
        .map((e, i) => ({ question: e.question!, selected: e.selected, durationMs: this.spent[i] }))
        .filter((a) => a.selected.length > 0)
      await this.repo.submitExam(record, answers)
      this.result = { ...record, entries }
      return this.result
    } finally {
      this.busy = false
    }
  }
}
