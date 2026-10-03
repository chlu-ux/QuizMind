import type { AnswerOutcome, Repo } from '@/data/repo'
import type { LocalQuestion, SessionData } from '@/data/types'

export type QuizOrder = 'random' | 'sequential'

/** Orders a question list for a session without touching the input. */
export function orderQuestions(qs: LocalQuestion[], order: QuizOrder, rng: () => number = Math.random): LocalQuestion[] {
  const out = [...qs]
  if (order === 'random') {
    for (let i = out.length - 1; i > 0; i--) {
      const j = Math.floor(rng() * (i + 1))
      ;[out[i], out[j]] = [out[j], out[i]]
    }
  }
  return out
}

/**
 * Order in which a question's options are shown: entry `d` is the original
 * index of the option displayed at position `d`. Single-choice options are
 * shuffled; judge options keep their fixed 正确 / 错误 order.
 */
export function optionOrder(q: LocalQuestion, rng: () => number = Math.random): number[] {
  const order = q.options.map((_, i) => i)
  if (q.type !== 'single') return order
  for (let i = order.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1))
    ;[order[i], order[j]] = [order[j], order[i]]
  }
  return order
}

/** Small seedable generator (mulberry32), so the same seed always shuffles the same way. */
export function seededRng(seed: number): () => number {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

/** FNV-1a, to mix a question id into the seed. */
function hashId(id: string): number {
  let h = 0x811c9dc5
  for (let i = 0; i < id.length; i++) h = Math.imul(h ^ id.charCodeAt(i), 0x01000193) >>> 0
  return h
}

/** An answer given in an earlier run of the same quiz, put back on resume. */
export interface RestoredAnswer {
  selected: number[]
  outcome: AnswerOutcome
}

/**
 * One run through a fixed list of questions. Remembers the choice and outcome
 * per position so the learner can step back and review.
 *
 * Options are shuffled once per question for the whole session, so stepping
 * back shows the same layout. Everything the session stores or grades
 * (`selected`, attempts) uses the question's original option indexes; only
 * `displayOptions` and `selectAt` know about the shuffled positions.
 */
export class QuizSession {
  index: number
  finished = false
  busy = false
  private startedAt = Date.now()
  private chosen: number[][]
  private outcomes: (AnswerOutcome | null)[]
  private orders: number[][]
  /** Seeds the option layout; saved with the quiz so a resumed run looks the same. */
  readonly seed: number

  /**
   * `rng` overrides the seeded shuffle (tests). `restored` puts back answers
   * given before the quiz was left, by question id.
   */
  constructor(
    readonly title: string,
    readonly questions: LocalQuestion[],
    private readonly repo: Repo,
    startAt = 0,
    rng?: () => number,
    opts: { seed?: number; restored?: Map<string, RestoredAnswer> } = {},
  ) {
    if (questions.length === 0) throw new Error('a quiz needs at least one question')
    this.seed = opts.seed ?? Math.floor(Math.random() * 2 ** 30)
    this.index = Math.min(Math.max(startAt, 0), questions.length - 1)
    this.chosen = questions.map(() => [])
    this.outcomes = questions.map(() => null)
    this.orders = questions.map((q) => optionOrder(q, rng ?? seededRng(this.seed ^ hashId(q.id))))
    questions.forEach((q, i) => {
      const r = opts.restored?.get(q.id)
      if (!r) return
      this.chosen[i] = [...r.selected]
      this.outcomes[i] = r.outcome
    })
  }

  get length() {
    return this.questions.length
  }
  get current() {
    return this.questions[this.index]
  }
  get isLast() {
    return this.index === this.questions.length - 1
  }
  get canGoBack() {
    return this.index > 0
  }
  get selected() {
    return this.chosen[this.index]
  }
  get outcome() {
    return this.outcomes[this.index]
  }
  get submitted() {
    return this.outcome !== null
  }
  get answeredCount() {
    return this.outcomes.filter((o) => o !== null).length
  }
  get correctCount() {
    return this.outcomes.filter((o) => o?.correct).length
  }
  /** Questions answered wrongly in this session, in order. */
  get missed(): LocalQuestion[] {
    return this.questions.filter((_, i) => this.outcomes[i] && !this.outcomes[i]!.correct)
  }

  /** What to save so the quiz can be continued: the order, the position and what was answered, by id. */
  snapshot(): SessionData {
    const answers: SessionData['answers'] = {}
    this.questions.forEach((q, i) => {
      const o = this.outcomes[i]
      if (o) answers[q.id] = { s: [...this.chosen[i]], c: o.correct }
    })
    return { title: this.title, ids: this.questions.map((q) => q.id), seed: this.seed, index: this.index, answers }
  }

  /** The current question's options in the order they are shown; `original` is the index to select, grade and store. */
  get displayOptions(): { text: string; original: number }[] {
    return this.orders[this.index].map((original) => ({ text: this.current.options[original], original }))
  }

  /** Selects by shown position (keyboard shortcuts). */
  selectAt(position: number) {
    const original = this.orders[this.index][position]
    if (original !== undefined) this.select(original)
  }

  /** Letter or number shown next to an option, given its original index. */
  labelOf(original: number): string {
    const position = this.orders[this.index].indexOf(original)
    return this.current.type === 'judge' ? String(position + 1) : String.fromCharCode(65 + position)
  }

  select(option: number) {
    if (this.submitted || option < 0 || option >= this.current.options.length) return
    this.chosen[this.index] = [option]
  }

  /** Grades the current selection and stores it. No-op without a selection. */
  async submit() {
    if (this.submitted || this.selected.length === 0 || this.busy) return
    this.busy = true
    const at = this.index
    try {
      const elapsed = Math.max(Date.now() - this.startedAt, 0)
      this.outcomes[at] = await this.repo.recordAnswer(this.current, this.selected, elapsed)
    } finally {
      this.busy = false
    }
  }

  next() {
    if (this.isLast) {
      if (this.answeredCount > 0) this.finished = true
    } else {
      this.index++
      this.startedAt = Date.now()
    }
  }

  previous() {
    if (this.canGoBack) this.index--
  }

  /** Reports the current question as wrong (hides it locally; uploaded on the next sync). */
  flagCurrent() {
    return this.repo.flagQuestion(this.current.id)
  }
}
