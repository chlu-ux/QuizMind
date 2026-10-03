/** JSON shapes of the app API (see api/openapi.yaml). Stored locally as-is. */

export interface Bank {
  id: string
  title: string
  description: string
  question_count: number
}

export interface Question {
  id: string
  bank_id: string
  type: 'single' | 'judge'
  stem: string
  options: string[]
  answer: number[]
  explanation: string
  difficulty: number
  tags: string[]
  source_quote: string
  sync_seq: number
}

/** A question as stored locally; hidden = withdrawn by the server (history is kept). */
export interface LocalQuestion extends Question {
  hidden: boolean
}

export interface AttemptDto {
  id: string
  question_id: string
  device_id: string
  answer: number[]
  is_correct: boolean
  duration_ms: number | null
  answered_at: number
}

/** synced: 0 = still in the outbox, 1 = uploaded. (Numbers because IndexedDB cannot index booleans.) */
export interface LocalAttempt extends AttemptDto {
  synced: 0 | 1
}

export interface StateDto {
  question_id: string
  fsrs: Record<string, unknown> | null
  due_at: number | null
  favorite: boolean
  wrong_count: number
  updated_at: number
}

/** dirty: 1 = changed locally and not uploaded yet. */
export interface LocalState extends StateDto {
  dirty: 0 | 1
}

export interface QuestionsPage {
  items: Question[]
  deleted: string[]
  next_seq: number
  has_more: boolean
}

export interface StatesPage {
  items: StateDto[]
  next_seq: number
  has_more: boolean
}

/**
 * The quiz a device left part-way, shared between devices. Questions and answers
 * are kept by id so questions withdrawn since are simply skipped on resume.
 * Same shape as SessionData in api/openapi.yaml.
 */
export interface SessionData {
  title: string
  ids: string[]
  seed: number
  index: number
  answers: Record<string, { s: number[]; c: boolean }>
}

/** data = null marks a finished quiz: a tombstone that clears the saved copy on every device. */
export interface SessionDto {
  scope: string
  data: SessionData | null
  updated_at: number
  device_id: string
}

/** dirty: 1 = changed locally and not uploaded yet. */
export interface LocalSession {
  scope: string
  data: SessionData | null
  updated_at: number
  dirty: 0 | 1
}

export interface SessionsPage {
  items: SessionDto[]
  next_seq: number
  has_more: boolean
}

export interface AttemptsPage {
  items: AttemptDto[]
  next_seq: number
  has_more: boolean
}

/** One question of a handed-in paper: question id, option indexes picked (empty = left blank), right or not. */
export interface ExamItemDto {
  q: string
  s: number[]
  c: boolean
}

/**
 * A finished mock exam, synced between devices. It never changes once handed in.
 * `items` lists the paper in order so any device can review it; records saved
 * before per-question detail existed have it empty.
 */
export interface ExamRecord {
  id: string
  bank_id: string
  title: string
  finished_at: number
  total: number
  correct: number
  /** Questions that got an answer; the rest were left blank. */
  answered: number
  /** Score 0-100: correct answers over all questions, blanks counting as wrong. */
  percent: number
  passed: boolean
  /** Time limit in seconds, null when the exam was untimed. */
  limit_sec: number | null
  used_ms: number
  device_id: string
  items: ExamItemDto[]
}

/** synced: 0 = still in the outbox, 1 = uploaded or downloaded. */
export interface LocalExam extends ExamRecord {
  synced: 0 | 1
}

export interface ExamsPage {
  items: ExamRecord[]
  next_seq: number
  has_more: boolean
}

/**
 * An exam in progress, kept on this device only so a reload or a killed app can
 * pick it up again. The clock keeps running from started_at, so a timed exam's
 * remaining time stays honest. There is at most one per bank.
 */
export interface ExamDraft {
  bank_id: string
  title: string
  /** The paper, in order. */
  ids: string[]
  /** Position of each question in the paper as first drawn; keeps its option shuffle stable if some are withdrawn. */
  slots: number[]
  seed: number
  started_at: number
  limit_sec: number | null
  index: number
  /** Option indexes picked, by question id; absent = blank. */
  answers: Record<string, number[]>
  /** Milliseconds spent on each question, by id. */
  spent: Record<string, number>
  /** Question ids flagged "check again". */
  marked: string[]
  saved_at: number
}
