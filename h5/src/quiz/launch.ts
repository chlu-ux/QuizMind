import { shallowRef } from 'vue'
import router from '@/router'
import type { LocalQuestion } from '@/data/types'
import type { ResumePlan } from './resume'
import { showToast } from '@/core/app'

export interface QuizLaunch {
  title: string
  questions: LocalQuestion[]
  startAt: number
  /** Where progress is saved (a bank id); undefined for quizzes not worth resuming. */
  scope?: string
  resume?: ResumePlan
  /** Remember which question the learner is on, so 按顺序刷题 can continue there. */
  sequential?: boolean
}

/** The quiz about to be shown. Set just before navigating to /quiz; a reload of /quiz has none and goes home. */
export const pendingQuiz = shallowRef<QuizLaunch | null>(null)

export function startQuiz(
  title: string,
  questions: LocalQuestion[],
  startAt = 0,
  replace = false,
  extra: { scope?: string; resume?: ResumePlan; sequential?: boolean } = {},
) {
  if (questions.length === 0) {
    showToast('没有可练习的题目')
    return
  }
  pendingQuiz.value = { title, questions, startAt, ...extra }
  return replace ? router.replace('/quiz') : router.push('/quiz')
}
