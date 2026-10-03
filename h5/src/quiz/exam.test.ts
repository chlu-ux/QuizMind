import { describe, expect, it } from 'vitest'
import { reactive } from 'vue'
import { freshDb } from '@/test-support'
import { Repo } from '@/data/repo'
import type { LocalQuestion } from '@/data/types'
import { drawExam, examCountChoices, ExamSession, PASS_PERCENT } from './exam'

const q = (id: string, o: Partial<LocalQuestion> = {}): LocalQuestion => ({
  id,
  bank_id: 'b1',
  type: 'single',
  stem: id,
  options: ['甲', '乙', '丙', '丁'],
  answer: [1],
  explanation: '',
  difficulty: 2,
  tags: [],
  source_quote: '',
  sync_seq: 1,
  hidden: false,
  ...o,
})

async function setup(ids: string[], limitSec: number | null = null) {
  const db = await freshDb()
  const qs = ids.map((id) => q(id))
  for (const x of qs) await db.put('questions', x)
  const clock = { t: 1_000_000 }
  const repo = new Repo(db, 'd', () => clock.t)
  const exam = new ExamSession('b1', '题库', qs, repo, limitSec, () => clock.t, 5)
  return { db, repo, exam, clock }
}

describe('exam helpers', () => {
  it('offers presets below the bank size plus "all"', () => {
    expect(examCountChoices(5)).toEqual([5])
    expect(examCountChoices(10)).toEqual([10])
    expect(examCountChoices(35)).toEqual([10, 20, 35])
    expect(examCountChoices(500)).toEqual([10, 20, 50, 100, 500])
  })

  it('draws distinct questions and never more than exist', () => {
    const qs = ['a', 'b', 'c', 'd', 'e'].map((id) => q(id))
    const drawn = drawExam(qs, 3)
    expect(new Set(drawn.map((x) => x.id)).size).toBe(3)
    expect(drawExam(qs, 99)).toHaveLength(5)
    expect(drawExam(qs, 0)).toEqual([])
    expect(qs.map((x) => x.id)).toEqual(['a', 'b', 'c', 'd', 'e'])
  })
})

describe('ExamSession', () => {
  it('records nothing until the paper is handed in, and lets answers change', async () => {
    const { db, exam } = await setup(['q1', 'q2', 'q3', 'q4'])
    exam.select(0)
    exam.select(1) // changed their mind
    expect(exam.selected).toEqual([1])
    exam.next()
    exam.select(1)
    expect(exam.answeredCount).toBe(2)
    expect(await db.count('attempts')).toBe(0)
    expect(await db.count('exams')).toBe(0)
  })

  it('grades on submit, counts blanks as wrong, and writes attempts, states and the exam record', async () => {
    const { db, repo, exam, clock } = await setup(['q1', 'q2', 'q3', 'q4'])
    exam.select(1) // q1 right
    clock.t += 5000
    exam.go(1)
    exam.select(0) // q2 wrong
    clock.t += 7000
    exam.go(3) // q3 left blank, q4 right
    exam.select(1)
    clock.t += 3000

    const r = await exam.submit()
    expect([r.total, r.correct, r.answered, r.percent]).toEqual([4, 2, 3, 50])
    expect(r.passed).toBe(false)
    expect(r.used_ms).toBe(15000)
    expect(r.items.map((i) => i.correct)).toEqual([true, false, false, true])
    expect(r.items[2].selected).toEqual([])

    const attempts = (await db.getAll('attempts')).sort((a, b) => a.question_id.localeCompare(b.question_id))
    expect(attempts.map((a) => [a.question_id, a.is_correct, a.duration_ms])).toEqual([
      ['q1', true, 5000],
      ['q2', false, 7000],
      ['q4', true, 3000],
    ])
    expect((await repo.wrongBook()).map((x) => x.id)).toEqual(['q2']) // exam misses feed the wrong book
    const [saved] = await repo.exams('b1')
    expect(saved).toMatchObject({ id: r.id, total: 4, correct: 2, percent: 50, passed: false })
    expect('items' in saved).toBe(false)
  })

  it('passes at the pass line', async () => {
    const { exam } = await setup(['q1', 'q2', 'q3', 'q4', 'q5'])
    for (let i = 0; i < 5; i++) {
      exam.go(i)
      exam.select(i < 3 ? 1 : 0) // 3 of 5 right = 60%
    }
    const r = await exam.submit()
    expect(r.percent).toBe(PASS_PERCENT)
    expect(r.passed).toBe(true)
  })

  it('submitting twice grades once and returns the same result', async () => {
    const { db, exam } = await setup(['q1', 'q2'])
    exam.select(1)
    const [a, b] = await Promise.all([exam.submit(), exam.submit()])
    expect(b).toBe(a)
    expect(await exam.submit()).toBe(a)
    expect(await db.count('attempts')).toBe(1)
    expect(await db.count('exams')).toBe(1)
    exam.select(0) // locked after submit
    expect(exam.submitted).toBe(true)
  })

  it('counts the time down and floors at zero', async () => {
    const { exam, clock } = await setup(['q1'], 60)
    expect(exam.remainingSec()).toBe(60)
    clock.t += 15_500
    expect(exam.remainingSec()).toBe(45)
    clock.t += 120_000
    expect(exam.remainingSec()).toBe(0)
    const untimed = (await setup(['q1'])).exam
    expect(untimed.remainingSec()).toBeNull()
  })

  it('grades original indexes whatever order the options are shown in, also under Vue reactivity', async () => {
    const { db, exam: plain } = await setup(['q1'])
    const exam = reactive(plain) as ExamSession
    const shown = exam.displayOptions
    expect(shown.map((o) => o.text).sort()).toEqual(['丁', '丙', '乙', '甲'])
    const right = shown.findIndex((o) => o.original === 1)
    exam.selectAt(right)
    expect(exam.selected).toEqual([1])
    const r = await exam.submit()
    expect(r.correct).toBe(1)
    expect((await db.getAll('attempts'))[0].answer).toEqual([1])
  })

  it('rejects an empty paper', async () => {
    const db = await freshDb()
    expect(() => new ExamSession('b', 't', [], new Repo(db, 'd'), null)).toThrow()
  })
})
