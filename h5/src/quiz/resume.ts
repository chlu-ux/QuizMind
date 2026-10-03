import type { Repo } from '@/data/repo'
import type { LocalQuestion, SessionData } from '@/data/types'
import type { RestoredAnswer } from './session'

/** A saved quiz rebuilt against the questions that still exist. */
export interface ResumePlan {
  title: string
  questions: LocalQuestion[]
  index: number
  seed: number
  restored: Map<string, RestoredAnswer>
}

/**
 * Reloads [saved] from the local database. Questions withdrawn or reported since
 * are dropped, and the position moves back so it still points at the same
 * question (or the one that followed it). Null when nothing is left to practise.
 */
export async function planResume(saved: SessionData, repo: Repo): Promise<ResumePlan | null> {
  const questions = await repo.questionsByIds(saved.ids)
  if (questions.length === 0) return null
  const alive = new Set(questions.map((q) => q.id))
  const before = saved.ids.slice(0, saved.index).filter((id) => alive.has(id)).length
  const index = Math.min(Math.max(before, 0), questions.length - 1)
  const restored = new Map<string, RestoredAnswer>()
  for (const [id, a] of Object.entries(saved.answers)) {
    if (!alive.has(id)) continue
    const state = await repo.getState(id)
    if (!state) continue // the local record is gone; let it be answered again
    restored.set(id, { selected: a.s, outcome: { correct: a.c, enteredWrongBook: false, state } })
  }
  return { title: saved.title, questions, index, seed: saved.seed, restored }
}
