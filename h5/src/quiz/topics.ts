import { tagLabeler } from '@/data/tags'
import type { LocalAttempt, LocalQuestion } from '@/data/types'

/**
 * The tag a question is filed under, the same way the stats page and the exam paper do it:
 * [merged] folds near-duplicates into their shorter tag ("UML 辨析" into "UML"), otherwise only
 * case, width and spacing are folded. All three places use [tagLabeler] over the bank's questions,
 * so a label seen on one of them names the same set of questions on the others.
 */
function labelsOf(qs: LocalQuestion[], merged: boolean) {
  const label = tagLabeler(qs.flatMap((q) => q.tags), merged)
  return (q: LocalQuestion) => new Set(q.tags.map(label))
}

/** The questions filed under [label], in the order of [qs]. A question with several tags shows up once. */
export function topicQuestions(qs: LocalQuestion[], label: string, merged: boolean): LocalQuestion[] {
  const of = labelsOf(qs, merged)
  return qs.filter((q) => of(q).has(label))
}

export interface TopicSummary {
  label: string
  count: number
  /** Questions of the topic answered at least once. */
  answered: number
  /** Questions of the topic answered wrongly at least once, however they went since. */
  missed: number
  attempts: number
  correct: number
  /** Share of the topic's attempts that were right, 0-100; null if it was never answered. */
  accuracy: number | null
}

/** Every knowledge point of [qs], biggest first, with how it has gone. Attempts for other questions are ignored. */
export function topicSummary(qs: LocalQuestion[], attempts: LocalAttempt[], merged: boolean): TopicSummary[] {
  const of = labelsOf(qs, merged)
  const byQuestion = new Map<string, { attempts: number; correct: number }>()
  for (const a of attempts) {
    const t = byQuestion.get(a.question_id) ?? { attempts: 0, correct: 0 }
    t.attempts++
    if (a.is_correct) t.correct++
    byQuestion.set(a.question_id, t)
  }
  const rows = new Map<string, TopicSummary>()
  for (const q of qs) {
    const t = byQuestion.get(q.id)
    for (const label of of(q)) {
      let r = rows.get(label)
      if (!r) rows.set(label, (r = { label, count: 0, answered: 0, missed: 0, attempts: 0, correct: 0, accuracy: null }))
      r.count++
      if (!t) continue
      r.answered++
      if (t.correct < t.attempts) r.missed++
      r.attempts += t.attempts
      r.correct += t.correct
    }
  }
  for (const r of rows.values()) r.accuracy = r.attempts ? Math.round((r.correct * 100) / r.attempts) : null
  return [...rows.values()].sort((a, b) => b.count - a.count || a.label.localeCompare(b.label, 'zh'))
}

/** Which questions of a topic to practise: all, only those never answered, or only those once answered wrongly. */
export type TopicFilter = 'all' | 'new' | 'missed'

/** How many questions of [t] the [filter] leaves. */
export function topicAvailable(t: TopicSummary, filter: TopicFilter): number {
  return filter === 'new' ? t.count - t.answered : filter === 'missed' ? t.missed : t.count
}

/** [qs] narrowed by [filter], judged from [attempts]. */
export function applyTopicFilter(qs: LocalQuestion[], attempts: LocalAttempt[], filter: TopicFilter): LocalQuestion[] {
  if (filter === 'all') return qs
  const seen = new Set<string>()
  const wrong = new Set<string>()
  for (const a of attempts) {
    seen.add(a.question_id)
    if (!a.is_correct) wrong.add(a.question_id)
  }
  return qs.filter((q) => (filter === 'new' ? !seen.has(q.id) : wrong.has(q.id)))
}
