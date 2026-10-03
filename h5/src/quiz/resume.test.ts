import { describe, expect, it } from 'vitest'
import { freshDb } from '@/test-support'
import { Repo } from '@/data/repo'
import type { LocalQuestion } from '@/data/types'
import { planResume } from './resume'
import { optionOrder, QuizSession, seededRng } from './session'

const q = (id: string, over: Partial<LocalQuestion> = {}): LocalQuestion => ({
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
  ...over,
})

async function setup(ids: string[]) {
  const db = await freshDb()
  const qs = ids.map((id) => q(id))
  for (const x of qs) await db.put('questions', x)
  return { db, qs, repo: new Repo(db, 'd') }
}

describe('seeded option layout', () => {
  it('is the same for the same seed and question, and differs across seeds', () => {
    const a = q('a')
    const layouts = new Set(Array.from({ length: 30 }, (_, s) => optionOrder(a, seededRng(s)).join()))
    expect(layouts.size).toBeGreaterThan(1)
    expect(optionOrder(a, seededRng(7))).toEqual(optionOrder(a, seededRng(7)))

    const make = (seed: number) => new QuizSession('t', [a, q('b')], null as never, 0, undefined, { seed })
    expect(make(5).displayOptions).toEqual(make(5).displayOptions)
  })
})

describe('resuming a quiz', () => {
  it('snapshot -> save -> plan -> restored session continues where it stopped', async () => {
    const { repo, qs } = await setup(['q1', 'q2', 'q3', 'q4'])
    const s = new QuizSession('题库', qs, repo, 0, undefined, { seed: 42 })
    s.select(1)
    await s.submit()
    s.next()
    s.select(0)
    await s.submit()
    s.next() // now on q3

    await repo.saveSession('b1', s.snapshot())
    const plan = (await planResume((await repo.savedSession('b1'))!, repo))!
    expect([plan.index, plan.seed, plan.restored.size]).toEqual([2, 42, 2])

    const again = new QuizSession(plan.title, plan.questions, repo, plan.index, undefined, {
      seed: plan.seed,
      restored: plan.restored,
    })
    expect(again.current.id).toBe('q3')
    expect([again.answeredCount, again.correctCount]).toEqual([2, 1])
    expect(again.displayOptions).toEqual(s.displayOptions) // same layout as before leaving

    again.previous()
    again.previous()
    expect(again.current.id).toBe('q1')
    expect(again.submitted).toBe(true)
    expect(again.selected).toEqual([1])
    expect(again.outcome!.correct).toBe(true)
  })

  it('drops withdrawn questions and keeps the position on the same question', async () => {
    const { repo, qs, db } = await setup(['q1', 'q2', 'q3', 'q4', 'q5'])
    const s = new QuizSession('题库', qs, repo, 0, undefined, { seed: 1 })
    s.select(1)
    await s.submit() // q1
    s.next()
    s.select(0)
    await s.submit() // q2
    s.next()
    s.next() // on q4
    await repo.saveSession('b1', s.snapshot())

    await repo.flagQuestion('q2') // hidden since the quiz was left
    const plan = (await planResume((await repo.savedSession('b1'))!, repo))!
    expect(plan.questions.map((x) => x.id)).toEqual(['q1', 'q3', 'q4', 'q5'])
    expect(plan.questions[plan.index].id).toBe('q4')
    expect([...plan.restored.keys()]).toEqual(['q1'])
    expect(await db.get('questions', 'q2')).toMatchObject({ hidden: true }) // history kept
  })

  it('is null when nothing is left', async () => {
    const { repo } = await setup(['q1'])
    await repo.saveSession('b1', { title: 't', ids: ['q1'], seed: 1, index: 0, answers: {} })
    await repo.flagQuestion('q1')
    expect(await planResume((await repo.savedSession('b1'))!, repo)).toBeNull()
  })
})
