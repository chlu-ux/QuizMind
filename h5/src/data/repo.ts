import { newUlid } from '@/core/ulid'
import type { Db } from './db'
import { afterAnswer, CLEAR_STREAK, inWrongBook, isCorrect, readProgress } from './progress'
import { buildReport, type BankReport } from './stats'
import type { Bank, ExamDraft, ExamRecord, LocalAttempt, LocalExam, LocalQuestion, LocalState, SessionData } from './types'

export interface AnswerOutcome {
  correct: boolean
  enteredWrongBook: boolean
  state: LocalState
}

/** What one device knows about how a question went; used to pick exam questions. */
export interface QuestionHistory {
  attempts: number
  lastCorrect: boolean
}

/** One answered question of an exam paper, to be written to the attempt log. */
export interface ExamAnswer {
  question: LocalQuestion
  selected: number[]
  durationMs: number
}

export interface BankStats {
  total: number
  answered: number
  /** Questions whose most recent attempt was correct. */
  correct: number
}

/** The two object stores an answer touches, from whichever transaction is open. */
interface AnswerStores {
  attempts: { add(v: LocalAttempt): Promise<unknown> }
  states: { get(k: string): Promise<LocalState | undefined>; put(v: LocalState): Promise<unknown> }
}

/** An exam row as stored: plain data only (reactive proxies cannot be cloned). */
function plainExam(e: LocalExam): LocalExam {
  return JSON.parse(JSON.stringify(e)) as LocalExam
}

/** Local data access. Reads exclude questions the server withdrew. */
export class Repo {
  constructor(
    readonly db: Db,
    readonly deviceId: string,
    private readonly now: () => number = Date.now,
  ) {}

  async banks(): Promise<Bank[]> {
    const all = await this.db.getAll('banks')
    return all.sort((a, b) => a.title.localeCompare(b.title, 'zh'))
  }

  async bankQuestions(bankId: string): Promise<LocalQuestion[]> {
    const all = await this.db.getAllFromIndex('questions', 'bank', bankId)
    return all.filter((q) => !q.hidden).sort((a, b) => a.sync_seq - b.sync_seq || a.id.localeCompare(b.id))
  }

  getState(questionId: string) {
    return this.db.get('states', questionId)
  }

  /** Wrong book, most recently touched first. */
  wrongBook() {
    return this.byState(inWrongBook)
  }

  favorites() {
    return this.byState((s) => !!s?.favorite)
  }

  private async byState(keep: (s: LocalState) => boolean): Promise<LocalQuestion[]> {
    const states = (await this.db.getAll('states')).filter(keep).sort((a, b) => b.updated_at - a.updated_at)
    const out: LocalQuestion[] = []
    for (const s of states) {
      const q = await this.db.get('questions', s.question_id)
      if (q && !q.hidden) out.push(q)
    }
    return out
  }

  /** Latest attempt result per question, for the given ids. */
  private async lastResults(ids: Set<string>): Promise<Map<string, boolean>> {
    const attempts = (await this.db.getAll('attempts')).filter((a) => ids.has(a.question_id))
    attempts.sort((a, b) => a.answered_at - b.answered_at)
    const last = new Map<string, boolean>()
    for (const a of attempts) last.set(a.question_id, a.is_correct)
    return last
  }

  async bankStats(bankId: string): Promise<BankStats> {
    const qs = await this.bankQuestions(bankId)
    const last = await this.lastResults(new Set(qs.map((q) => q.id)))
    return { total: qs.length, answered: last.size, correct: [...last.values()].filter(Boolean).length }
  }

  /** Practice statistics for a bank, from the attempt log. */
  async bankReport(bankId: string): Promise<BankReport> {
    const qs = await this.bankQuestions(bankId)
    const ids = new Set(qs.map((q) => q.id))
    const attempts = (await this.db.getAll('attempts')).filter((a: LocalAttempt) => ids.has(a.question_id))
    const wrongIds = new Set((await this.wrongBook()).map((q) => q.id))
    return buildReport(qs, attempts, wrongIds, this.now(), await this.exams(bankId))
  }

  /**
   * Hands in an exam: every answered question goes into the attempt log and the learning
   * state, the result is stored and the unfinished-exam draft is dropped, all in one
   * transaction. It either all happens or none of it does, so a retry never double-counts.
   */
  async submitExam(record: ExamRecord, answers: ExamAnswer[]) {
    const tx = this.db.transaction(['attempts', 'states', 'exams', 'examDrafts'], 'readwrite')
    try {
      const at = this.now()
      const stores = { attempts: tx.objectStore('attempts'), states: tx.objectStore('states') }
      for (const a of answers) await this.applyAnswer(stores, a.question, a.selected, a.durationMs, at)
      await tx.objectStore('exams').put(plainExam({ ...record, synced: 0 }))
      await tx.objectStore('examDrafts').delete(record.bank_id)
      await tx.done
    } catch (e) {
      // A failed request aborts the transaction by itself; a plain exception in between would not.
      tx.done.catch(() => {})
      try {
        tx.abort()
      } catch {
        /* already finished or aborted */
      }
      throw e
    }
  }

  /** Finished exams of a bank, newest first. */
  async exams(bankId: string): Promise<ExamRecord[]> {
    const all = await this.db.getAllFromIndex('exams', 'bank', bankId)
    return all.sort((a, b) => b.finished_at - a.finished_at).map(({ synced: _s, ...rec }) => rec)
  }

  async exam(id: string): Promise<ExamRecord | null> {
    const row = await this.db.get('exams', id)
    if (!row) return null
    const { synced: _s, ...rec } = row
    return rec
  }

  // ---- exam in progress (this device only) ----

  async saveExamDraft(draft: ExamDraft) {
    // Callers may hold Vue reactive proxies, which IndexedDB cannot structured-clone.
    await this.db.put('examDrafts', JSON.parse(JSON.stringify(draft)) as ExamDraft)
  }

  examDraft(bankId: string) {
    return this.db.get('examDrafts', bankId)
  }

  /** The most recently touched unfinished exam of any bank. */
  async latestExamDraft(): Promise<ExamDraft | null> {
    const all = await this.db.getAll('examDrafts')
    return all.sort((a, b) => b.saved_at - a.saved_at)[0] ?? null
  }

  clearExamDraft(bankId: string) {
    return this.db.delete('examDrafts', bankId)
  }

  /** How each of [ids] has gone so far, for those answered at least once. */
  async practiceHistory(ids: Set<string>): Promise<Map<string, QuestionHistory>> {
    const attempts = (await this.db.getAll('attempts')).filter((a) => ids.has(a.question_id))
    attempts.sort((a, b) => a.answered_at - b.answered_at)
    const out = new Map<string, QuestionHistory>()
    for (const a of attempts) {
      const h = out.get(a.question_id) ?? { attempts: 0, lastCorrect: false }
      h.attempts++
      h.lastCorrect = a.is_correct
      out.set(a.question_id, h)
    }
    return out
  }

  async answeredIds(ids: string[]): Promise<Set<string>> {
    return new Set((await this.lastResults(new Set(ids))).keys())
  }

  /** Answers waiting in the outbox. */
  pendingUploads() {
    return this.db.countFromIndex('attempts', 'synced', 0)
  }

  /** Appends to the attempt log (outbox) and updates the learning state in one transaction. */
  async recordAnswer(question: LocalQuestion, selected: number[], durationMs: number): Promise<AnswerOutcome> {
    const tx = this.db.transaction(['attempts', 'states'], 'readwrite')
    const stores = { attempts: tx.objectStore('attempts'), states: tx.objectStore('states') }
    const outcome = await this.applyAnswer(stores, question, selected, durationMs, this.now())
    await tx.done
    return outcome
  }

  private async applyAnswer(
    tx: AnswerStores,
    question: LocalQuestion,
    selected: number[],
    durationMs: number,
    now: number,
  ): Promise<AnswerOutcome> {
    // Views hand us Vue reactive proxies, which IndexedDB cannot structured-clone; store plain copies.
    selected = [...selected]
    const correct = isCorrect(selected, question.answer)
    await tx.attempts.add({
      id: newUlid(now),
      question_id: question.id,
      device_id: this.deviceId,
      answer: selected,
      is_correct: correct,
      duration_ms: durationMs,
      answered_at: now,
      synced: 0,
    })
    const before = await tx.states.get(question.id)
    const wasIn = inWrongBook(before)
    const state: LocalState = {
      question_id: question.id,
      fsrs: { ...afterAnswer(readProgress(before?.fsrs), correct, now) },
      due_at: before?.due_at ?? null,
      favorite: before?.favorite ?? false,
      wrong_count: (before?.wrong_count ?? 0) + (correct ? 0 : 1),
      updated_at: now,
      dirty: 1,
    }
    await tx.states.put(state)
    return { correct, enteredWrongBook: !wasIn && inWrongBook(state), state }
  }

  private async touchState(questionId: string, patch: (s: LocalState) => void) {
    const tx = this.db.transaction('states', 'readwrite')
    const s: LocalState = (await tx.store.get(questionId)) ?? {
      question_id: questionId,
      fsrs: null,
      due_at: null,
      favorite: false,
      wrong_count: 0,
      updated_at: 0,
      dirty: 0,
    }
    patch(s)
    s.updated_at = this.now()
    s.dirty = 1
    await tx.store.put(s)
    await tx.done
  }

  setFavorite(questionId: string, favorite: boolean) {
    return this.touchState(questionId, (s) => {
      s.favorite = favorite
    })
  }

  /** Takes the question out of the wrong book without touching its history. */
  async clearFromWrongBook(questionId: string) {
    if (!(await this.getState(questionId))) return
    await this.touchState(questionId, (s) => {
      s.fsrs = { ...readProgress(s.fsrs), streak: CLEAR_STREAK }
    })
  }

  // ---- saved quizzes ----

  /** The quiz left part-way in [scope] (a bank id), or null if none, or if it was finished. */
  async savedSession(scope: string): Promise<SessionData | null> {
    return (await this.db.get('sessions', scope))?.data ?? null
  }

  /** Saves the quiz of [scope], stamped and marked for upload. */
  async saveSession(scope: string, data: SessionData) {
    // Callers may hold Vue reactive proxies, which IndexedDB cannot structured-clone.
    const plain = JSON.parse(JSON.stringify(data)) as SessionData
    await this.db.put('sessions', { scope, data: plain, updated_at: this.now(), dirty: 1 })
  }

  /** Marks the quiz finished. Kept as a tombstone so the other devices clear theirs too. */
  async clearSession(scope: string) {
    await this.db.put('sessions', { scope, data: null, updated_at: this.now(), dirty: 1 })
  }

  /** The visible questions among [ids], in the order of [ids]. Withdrawn or reported ones are left out. */
  async questionsByIds(ids: string[]): Promise<LocalQuestion[]> {
    const out: LocalQuestion[] = []
    for (const id of ids) {
      const q = await this.db.get('questions', id)
      if (q && !q.hidden) out.push(q)
    }
    return out
  }

  /** Queues a "looks wrong" report and hides the question here right away; the server confirms later. */
  async flagQuestion(questionId: string) {
    const tx = this.db.transaction(['flags', 'questions'], 'readwrite')
    await tx.objectStore('flags').put({ question_id: questionId, created_at: this.now() })
    const q = await tx.objectStore('questions').get(questionId)
    if (q) await tx.objectStore('questions').put({ ...q, hidden: true })
    await tx.done
  }
}
