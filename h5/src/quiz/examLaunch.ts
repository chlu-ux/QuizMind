import { shallowRef } from 'vue'
import router from '@/router'
import type { ExamDraft, LocalQuestion } from '@/data/types'

export interface ExamLaunch {
  bankId: string
  title: string
  questions: LocalQuestion[]
  /** Seconds allowed, null for an untimed exam. */
  limitSec: number | null
  /** Set when picking up an unfinished exam; questions is then the paper's remaining questions. */
  draft?: ExamDraft
}

/**
 * The exam about to start. Set just before navigating to /exam and taken by the page
 * once it opens. A reload of /exam has none and resumes the saved exam instead, if any.
 */
export const pendingExam = shallowRef<ExamLaunch | null>(null)

export function startExam(launch: ExamLaunch) {
  pendingExam.value = launch
  return router.push('/exam')
}
