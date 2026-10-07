import { describe, expect, it } from 'vitest'
import type { Lesson, LocalAttempt, LocalQuestion } from '@/data/types'
import {
  groupChapters,
  lessonBlocks,
  lessonProgress,
  lessonQuestions,
  lessonTitle,
  nextToStudy,
  shortTitles,
  splitSentences,
} from './lessons'

const lesson = (id: string, o: Partial<Lesson> = {}): Lesson => ({
  id,
  bank_id: 'b1',
  document_id: 'd1',
  document_title: '考点精讲',
  document_created_at: 1,
  seq: 0,
  heading_path: `考点精讲 > ${id}`,
  text: '正文',
  ...o,
})

const question = (id: string, chunk?: string): LocalQuestion => ({
  id,
  bank_id: 'b1',
  type: 'single',
  stem: id,
  options: ['a', 'b', 'c', 'd'],
  answer: [0],
  explanation: '',
  difficulty: 2,
  tags: [],
  source_quote: '',
  sync_seq: 1,
  hidden: false,
  chunk_id: chunk,
})

let at = 0
const attempt = (question_id: string, is_correct: boolean): LocalAttempt => ({
  id: `a${++at}`,
  question_id,
  device_id: 'd',
  answer: [0],
  is_correct,
  duration_ms: 1000,
  answered_at: at,
  synced: 1,
})

describe('titles', () => {
  it('a section is named by the last part of its path', () => {
    expect(lessonTitle(lesson('x', { heading_path: '考点精讲 > 2.1 操作系统概述' }))).toBe('2.1 操作系统概述')
    expect(lessonTitle(lesson('x', { heading_path: '开头' }))).toBe('开头')
  })

  it('chapter names drop what the documents share and keep the part in brackets', () => {
    expect(
      shortTitles([
        '软件设计师（中级）考点精讲',
        '软件设计师（中级）考点精讲（操作系统）',
        '软件设计师（中级）考点精讲（软件工程（上）：过程、需求与设计）',
      ]),
    ).toEqual(['软件设计师（中级）考点精讲', '操作系统', '软件工程（上）：过程、需求与设计'])
  })

  it('leaves a lone title, or titles with nothing in common, as they are', () => {
    expect(shortTitles(['讲义'])).toEqual(['讲义'])
    expect(shortTitles(['甲篇', '乙篇'])).toEqual(['甲篇', '乙篇'])
  })
})

describe('groupChapters', () => {
  it('orders chapters as the documents were added and sections by position', () => {
    const chapters = groupChapters([
      lesson('b2', { document_id: 'd2', document_title: '讲义（二）', document_created_at: 20, seq: 1 }),
      lesson('a2', { document_id: 'd1', document_title: '讲义（一）', document_created_at: 10, seq: 1 }),
      lesson('b1', { document_id: 'd2', document_title: '讲义（二）', document_created_at: 20, seq: 0 }),
      lesson('a1', { document_id: 'd1', document_title: '讲义（一）', document_created_at: 10, seq: 0 }),
    ])
    expect(chapters.map((c) => [c.title, c.lessons.map((l) => l.id)])).toEqual([
      ['一', ['a1', 'a2']],
      ['二', ['b1', 'b2']],
    ])
  })
})

describe('lessonProgress', () => {
  const ls = [lesson('L1'), lesson('L2'), lesson('L3'), lesson('L4')]
  const qs = [
    question('q1', 'L2'),
    question('q2', 'L2'),
    ...[1, 2, 3, 4, 5, 6].map((i) => question(`m${i}`, 'L3')),
    question('old'), // pulled before questions knew their section
  ]

  it('is new until read, then read; questions are counted per section', () => {
    const p = lessonProgress(ls, qs, [], new Set(['L1']))
    expect(p.get('L1')).toMatchObject({ state: 'read', total: 0, answered: 0, accuracy: null })
    expect(p.get('L2')).toMatchObject({ state: 'new', total: 2 })
    expect(p.get('L3')).toMatchObject({ state: 'new', total: 6 })
    expect(p.get('L4')).toMatchObject({ state: 'new', total: 0 })
  })

  it('practising makes a section practised, even if it was never opened', () => {
    const p = lessonProgress(ls, qs, [attempt('q1', false)], new Set())
    expect(p.get('L2')).toMatchObject({ state: 'practiced', answered: 1, correct: 0, accuracy: 0 })
  })

  it('a short section is mastered once all its questions were answered and 80% are right', () => {
    expect(lessonProgress(ls, qs, [attempt('q1', true)], new Set()).get('L2')!.state).toBe('practiced')
    expect(lessonProgress(ls, qs, [attempt('q1', true), attempt('q2', true)], new Set()).get('L2')).toMatchObject({
      state: 'mastered',
      accuracy: 100,
    })
    expect(lessonProgress(ls, qs, [attempt('q1', true), attempt('q2', false)], new Set()).get('L2')!.state).toBe('practiced')
  })

  it('a long section needs five answered, and judges each question by its latest attempt', () => {
    const four = ['m1', 'm2', 'm3', 'm4'].map((q) => attempt(q, true))
    expect(lessonProgress(ls, qs, four, new Set()).get('L3')!.state).toBe('practiced')
    const five = [...four, attempt('m5', true)]
    expect(lessonProgress(ls, qs, five, new Set()).get('L3')!.state).toBe('mastered')
    // one wrong out of five is exactly 80%
    expect(lessonProgress(ls, qs, [...four, attempt('m5', false)], new Set()).get('L3')!.state).toBe('mastered')
    // a wrong answer given later overrides the earlier right one: 3 of 5 now
    const later = [...five, attempt('m1', false), attempt('m2', false)]
    expect(lessonProgress(ls, qs, later, new Set()).get('L3')).toMatchObject({ state: 'practiced', correct: 3, accuracy: 60 })
  })

  it('finds the questions of a section', () => {
    expect(lessonQuestions('L2', qs).map((q) => q.id)).toEqual(['q1', 'q2'])
  })
})

describe('nextToStudy', () => {
  const ls = [lesson('L1'), lesson('L2'), lesson('L3')]
  const qs = [question('q1', 'L1'), question('q2', 'L3')]

  it('goes to the first section not read yet, though practising it does not make it read', () => {
    const p = lessonProgress(ls, qs, [attempt('q1', true)], new Set())
    expect(p.get('L1')).toMatchObject({ read: false, state: 'mastered' })
    expect(nextToStudy(ls, p)?.id).toBe('L1')
    expect(nextToStudy(ls, lessonProgress(ls, qs, [], new Set(['L1'])))?.id).toBe('L2')
  })

  it('then to the first one not mastered, and to nothing when all are read and mastered', () => {
    const read = new Set(['L1', 'L2', 'L3'])
    expect(nextToStudy(ls, lessonProgress(ls, qs, [], read))?.id).toBe('L1')
    expect(nextToStudy(ls, lessonProgress(ls, qs, [attempt('q1', true)], read))?.id).toBe('L3') // L2 has no questions to master
    // L2 has no questions, so it can never be mastered: reading it is all that can be asked
    const done = lessonProgress(ls, qs, [attempt('q1', true), attempt('q2', true)], read)
    expect(nextToStudy(ls, done)).toBeNull()
  })
})

describe('reading layout', () => {
  it('cuts a sentence at 。！？ and keeps a closing bracket or quote with it', () => {
    expect(splitSentences('甲是乙（见下文）。丙是丁！戊呢？“好。”己')).toEqual(['甲是乙（见下文）。', '丙是丁！', '戊呢？', '“好。”', '己'])
  })

  it('joins hard-wrapped lines without a gap, except between two Latin words', () => {
    expect(splitSentences('进程是程序\n的一次执行。')).toEqual(['进程是程序的一次执行。'])
    expect(splitSentences('use the\nstack。')).toEqual(['use the stack。'])
  })

  it('shows a prose paragraph one sentence at a time and leaves lists, code and pictures alone', () => {
    const text = ['甲。乙。', '', '- 项一', '- 项二', '', '```', '代码。第二句。', '', '仍是代码。', '```', '', '一句话。', '', '![图](media:x)。再来一句。']
    const blocks = lessonBlocks(text.join('\n'))
    expect(blocks).toEqual([
      { kind: 'prose', sentences: ['甲。', '乙。'] },
      { kind: 'md', source: '- 项一\n- 项二' },
      { kind: 'md', source: '```\n代码。第二句。\n\n仍是代码。\n```' },
      { kind: 'md', source: '一句话。' },
      { kind: 'md', source: '![图](media:x)。再来一句。' },
    ])
  })
})
