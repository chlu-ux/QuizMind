import { newUlid } from '@/core/ulid'
import type { Repo } from '@/data/repo'
import type { ExamRecord, LocalQuestion } from '@/data/types'
import { optionOrder, seededRng } from './session'

/** Score needed to pass a mock exam, in percent. */
export const PASS_PERCENT = 60

/** Question counts offered for a bank with [available] questions; the last choice is always "all of them". */
export function examCountChoices(available: number): number[] {
  const presets = [10, 20, 50, 100].filter((n) => n < available)
  return [...presets, available]
}

/** [count] distinct questions picked at random. */
export function drawExam(qs: LocalQuestion[], count: number, rng: () => number = Math.random): LocalQuestion[] {
  const pool = [...qs]
  for (let i = pool.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1))
    ;[pool[i], pool[j]] = [pool[j], pool[i]]
  }
  return pool.slice(0, Math.max(0, Math.min(count, pool.length)))
}

export interface ExamItem {
  question: LocalQuestion
  /** Original option indexes picked; empty when left blank. */
  selected: number[]
  correct: boolean
}

export interface ExamResult extends ExamRecord {
  items: ExamItem[]
}

/**
 * A mock exam: a fixed list of questions answered with no feedback, answers
 * changeable until the whole paper is handed in (by the learner, or when the
 * time runs out). Only then is anything graded and written to the attempt log,
 * so a half-finished exam leaves no trace.
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
  private orders: number[][]
  private enteredAt: number
  private inFlight: Promise<ExamResult> | null = null
  private readonly startedAt: number
  readonly seed: number

  constructor(
    readonly bankId: string,
    readonly title: string,
    readonly questions: LocalQuestion[],
    private readonly repo: Repo,
    /** Time allowed in seconds, null for none. */
    readonly limitSec: number | null,
    private readonly clock: () => number = Date.now,
    seed?: number,
  ) {
    if (questions.length === 0) throw new Error('an exam needs at least one question')
    this.seed = seed ?? Math.floor(Math.random() * 2 ** 30)
    this.startedAt = this.enteredAt = clock()
    this.chosen = questions.map(() => [])
    this.spent = questions.map(() => 0)
    this.orders = questions.map((q, i) => optionOrder(q, seededRng(this.seed + i * 7919)))
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
    if (this.submitted || option < 0 || option >= this.current.options.length) return
    this.chosen[this.index] = [option]
  }

  selectAt(position: number) {
    const original = this.orders[this.index][position]
    if (original !== undefined) this.select(original)
  }

  /** Moves to question [i], crediting the time spent on the one being left. */
  go(i: number) {
    if (this.submitted || i < 0 || i >= this.length || i === this.index) return
    this.leave()
    this.index = i
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
      const items: ExamItem[] = []
      for (let i = 0; i < this.length; i++) {
        const question = this.questions[i]
        const selected = [...this.chosen[i]]
        if (selected.length === 0) {
          items.push({ question, selected, correct: false })
          continue
        }
        const outcome = await this.repo.recordAnswer(question, selected, this.spent[i])
        items.push({ question, selected, correct: outcome.correct })
      }
      const correct = items.filter((it) => it.correct).length
      const pct = Math.round((correct * 100) / this.length)
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
        used_ms: Math.max(finishedAt - this.startedAt, 0),
      }
      await this.repo.saveExam(record)
      this.result = { ...record, items }
      return this.result
    } finally {
      this.busy = false
    }
  }
}
