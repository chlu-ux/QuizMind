import type { LocalState } from './types'

/**
 * The app's own progress record, kept in the opaque `fsrs` field of a question
 * state until real FSRS scheduling replaces it. It travels through the server
 * untouched, so every device sees the same wrong-book membership.
 */
export interface ProgressRecord {
  v: 1
  streak: number // consecutive correct answers since the last miss
  last: number | null // time of the last answer
}

/** A question leaves the wrong book after this many right answers in a row. */
export const CLEAR_STREAK = 2

export function readProgress(fsrs: Record<string, unknown> | null | undefined): ProgressRecord {
  const streak = typeof fsrs?.streak === 'number' ? fsrs.streak : 0
  const last = typeof fsrs?.last === 'number' ? fsrs.last : null
  return { v: 1, streak, last }
}

export function afterAnswer(p: ProgressRecord, correct: boolean, at: number): ProgressRecord {
  return { v: 1, streak: correct ? p.streak + 1 : 0, last: at }
}

/** Missed at least once and not yet answered right twice in a row. */
export function inWrongBook(s: LocalState | undefined): boolean {
  return !!s && s.wrong_count > 0 && readProgress(s.fsrs).streak < CLEAR_STREAK
}

/** A selection is right only if it matches the answer set exactly. */
export function isCorrect(selected: number[], answer: number[]): boolean {
  const a = new Set(selected)
  const b = new Set(answer)
  if (a.size !== b.size) return false
  for (const x of b) if (!a.has(x)) return false
  return true
}
