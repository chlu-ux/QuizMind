import { shallowRef } from 'vue'
import router from '@/router'
import type { LocalQuestion } from '@/data/types'

export interface ExamLaunch {
  bankId: string
  title: string
  questions: LocalQuestion[]
  /** Seconds allowed, null for an untimed exam. */
  limitSec: number | null
}

/** The exam about to start. Set just before navigating to /exam; a reload of /exam has none and goes home. */
export const pendingExam = shallowRef<ExamLaunch | null>(null)

export function startExam(launch: ExamLaunch) {
  pendingExam.value = launch
  return router.push('/exam')
}
