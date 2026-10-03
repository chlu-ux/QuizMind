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
}

/** The quiz about to be shown. Set just before navigating to /quiz; a reload of /quiz has none and goes home. */
export const pendingQuiz = shallowRef<QuizLaunch | null>(null)

export function startQuiz(
  title: string,
  questions: LocalQuestion[],
  startAt = 0,
  replace = false,
  extra: { scope?: string; resume?: ResumePlan } = {},
) {
  if (questions.length === 0) {
    showToast('没有可练习的题目')
    return
  }
  pendingQuiz.value = { title, questions, startAt, ...extra }
  return replace ? router.replace('/quiz') : router.push('/quiz')
}
