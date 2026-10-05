import { describe, expect, it } from 'vitest'
import type { LocalAttempt, LocalQuestion } from '@/data/types'
import { applyTopicFilter, topicAvailable, topicQuestions, topicSummary } from './topics'
import { paperPool } from './exam'

const q = (id: string, tags: string[]): LocalQuestion => ({
  id,
  bank_id: 'b',
  type: 'single',
  stem: id,
  options: ['甲', '乙', '丙', '丁'],
  answer: [0],
  explanation: '',
  difficulty: 2,
  tags,
  source_quote: '',
  sync_seq: 1,
  hidden: false,
})

let n = 0
const at = (question_id: string, is_correct: boolean): LocalAttempt => ({
  id: `a${++n}`,
  question_id,
  device_id: 'd',
  answer: [0],
  is_correct,
  duration_ms: 1000,
  answered_at: n,
  synced: 1,
})

const ids = (qs: LocalQuestion[]) => qs.map((x) => x.id)

describe('topicQuestions', () => {
  const qs = [
    q('1', ['UML']),
    q('2', ['UML 辨析']),
    q('3', ['uml', '设计模式']),
    q('4', ['设计模式']),
    q('5', []),
    q('6', ['UML']), // makes "UML" the commonest spelling, so it is the label
  ]

  it('merges related tags when asked, and only case/width/spacing otherwise', () => {
    expect(ids(topicQuestions(qs, 'UML', true))).toEqual(['1', '2', '3', '6'])
    expect(ids(topicQuestions(qs, 'UML', false))).toEqual(['1', '3', '6']) // "UML 辨析" stays apart
    expect(ids(topicQuestions(qs, 'UML 辨析', false))).toEqual(['2'])
  })

  it('lists a question with several tags once, and never an untagged one', () => {
    const multi = [q('x', ['缓存', 'Cache', '缓存 ']), q('y', [])]
    const all = topicQuestions(multi, topicSummary(multi, [], false)[0].label, false)
    expect(ids(all)).toEqual(['x'])
    expect(topicQuestions(qs, '', true)).toEqual([])
    expect(topicQuestions(qs, '不存在', true)).toEqual([])
  })

  it('folds full-width and upper-case spellings together', () => {
    const list = [q('1', ['ＵＭＬ']), q('2', ['uml']), q('3', ['UML'])]
    const [t] = topicSummary(list, [], true)
    expect(ids(topicQuestions(list, t.label, true))).toEqual(['1', '2', '3'])
  })

  it('names the same questions as the exam paper does for the same label', () => {
    for (const label of ['UML', '设计模式']) {
      expect(ids(topicQuestions(qs, label, true))).toEqual(ids(paperPool(qs, [label])))
    }
  })
})

describe('topicSummary', () => {
  const qs = [q('1', ['锁']), q('2', ['锁', '线程']), q('3', ['线程']), q('4', ['范式'])]
  const attempts = [at('1', false), at('1', true), at('2', true), at('4', true), at('zzz', false)]

  it('counts questions, answered questions and accuracy per topic, biggest first', () => {
    const rows = topicSummary(qs, attempts, true)
    expect(rows.map((r) => r.label)).toEqual(['锁', '线程', '范式']) // 锁 and 线程 tie on count; pinyin order
    const by = Object.fromEntries(rows.map((r) => [r.label, r]))
    expect(by['锁']).toMatchObject({ count: 2, answered: 2, missed: 1, attempts: 3, correct: 2, accuracy: 67 })
    expect(by['线程']).toMatchObject({ count: 2, answered: 1, missed: 0, attempts: 1, correct: 1, accuracy: 100 })
    expect(by['范式']).toMatchObject({ count: 1, answered: 1, accuracy: 100 })
  })

  it('has no accuracy for a topic nobody answered, and ignores attempts of unknown questions', () => {
    const rows = topicSummary([q('1', ['锁'])], [at('other', false)], true)
    expect(rows).toEqual([{ label: '锁', count: 1, answered: 0, missed: 0, attempts: 0, correct: 0, accuracy: null }])
  })

  it('breaks ties on count by label and is empty without tags', () => {
    const rows = topicSummary([q('1', ['乙']), q('2', ['甲'])], [], true)
    expect(rows.map((r) => r.label)).toEqual(['甲', '乙'])
    expect(topicSummary([q('1', [])], [], true)).toEqual([])
  })

  it('counts a multi-tag question under each of its topics', () => {
    const rows = topicSummary([q('1', ['A类', 'B类'])], [at('1', true)], false)
    expect(rows.map((r) => [r.label, r.count, r.answered])).toEqual([['A类', 1, 1], ['B类', 1, 1]])
  })
})

describe('filters', () => {
  const qs = [q('1', ['锁']), q('2', ['锁']), q('3', ['锁'])]
  const attempts = [at('1', false), at('1', true), at('2', true)]

  it('keeps only unanswered, or only once-wrong, questions', () => {
    expect(ids(applyTopicFilter(qs, attempts, 'all'))).toEqual(['1', '2', '3'])
    expect(ids(applyTopicFilter(qs, attempts, 'new'))).toEqual(['3'])
    expect(ids(applyTopicFilter(qs, attempts, 'missed'))).toEqual(['1']) // wrong once, right since: still "missed"
  })

  it('topicAvailable agrees with the filtered list', () => {
    const [t] = topicSummary(qs, attempts, true)
    for (const f of ['all', 'new', 'missed'] as const) {
      expect(topicAvailable(t, f)).toBe(applyTopicFilter(topicQuestions(qs, t.label, true), attempts, f).length)
    }
  })
})
