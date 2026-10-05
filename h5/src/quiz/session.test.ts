import { describe, expect, it } from 'vitest'
import { reactive } from 'vue'
import { freshDb } from '@/test-support'
import { Repo } from '@/data/repo'
import type { LocalQuestion } from '@/data/types'
import { optionOrder, orderQuestions, QuizSession } from './session'

const q = (id: string): LocalQuestion => ({
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
})

describe('orderQuestions', () => {
  it('keeps order or shuffles without losing items or mutating the input', () => {
    const qs = ['a', 'b', 'c', 'd', 'e', 'f'].map(q)
    expect(orderQuestions(qs, 'sequential').map((x) => x.id)).toEqual(['a', 'b', 'c', 'd', 'e', 'f'])
    let seed = 7
    const rng = () => ((seed = (seed * 16807) % 2147483647) / 2147483647)
    const shuffled = orderQuestions(qs, 'random', rng)
    expect(shuffled.map((x) => x.id).sort()).toEqual(['a', 'b', 'c', 'd', 'e', 'f'])
    expect(qs.map((x) => x.id)).toEqual(['a', 'b', 'c', 'd', 'e', 'f'])
  })
})

describe('QuizSession', () => {
  it('answer, review, finish and collect misses', async () => {
    const db = await freshDb()
    const qs = [q('q1'), q('q2'), q('q3')]
    for (const x of qs) await db.put('questions', x)
    const s = new QuizSession('t', qs, new Repo(db, 'd'))

    await s.submit()
    expect(s.submitted).toBe(false) // cannot submit without a choice

    s.select(0)
    await s.submit()
    expect(s.outcome!.correct).toBe(false)
    s.select(2)
    expect(s.selected).toEqual([0]) // locked after submit

    s.next()
    s.select(1)
    await s.submit()
    expect(s.outcome!.correct).toBe(true)

    s.previous()
    expect(s.index).toBe(0)
    expect(s.submitted).toBe(true) // stepping back shows the earlier result

    s.next()
    s.next()
    expect(s.isLast).toBe(true)
    s.select(1)
    await s.submit()
    s.next()
    expect(s.finished).toBe(true)
    expect([s.answeredCount, s.correctCount]).toEqual([3, 2])
    expect(s.missed.map((x) => x.id)).toEqual(['q1'])
  })

  it('does not finish when nothing was answered, and rejects an empty list', async () => {
    const db = await freshDb()
    const s = new QuizSession('t', [q('a'), q('b')], new Repo(db, 'd'))
    s.next()
    s.next()
    expect(s.finished).toBe(false)
    expect(() => new QuizSession('t', [], new Repo(db, 'd'))).toThrow()
  })

  it('works when the session is wrapped in Vue reactivity, as the quiz view does', async () => {
    // Reactive proxies cannot be structured-cloned into IndexedDB; this broke in the browser once.
    const db = await freshDb()
    const qs = [q('q1')]
    await db.put('questions', qs[0])
    const s = reactive(new QuizSession('t', qs, new Repo(db, 'd'))) as QuizSession
    s.select(1)
    await s.submit()
    expect(s.outcome!.correct).toBe(true)
    const [a] = await db.getAll('attempts')
    expect(a.answer).toEqual([1])
  })
})

describe('QuizSession timing', () => {
  async function setup(...ids: string[]) {
    const db = await freshDb()
    const qs = ids.map(q)
    for (const x of qs) await db.put('questions', x)
    let t = 10_000
    const s = new QuizSession('t', qs, new Repo(db, 'd'), 0, undefined, { clock: () => t })
    return { db, s, advance: (ms: number) => (t += ms) }
  }

  it('times the answer up to submit and the reading after it as review time', async () => {
    const { db, s, advance } = await setup('q1', 'q2')
    advance(8000)
    s.select(1)
    await s.submit()
    advance(20_000) // reading the explanation
    s.next()
    await s.flush() // the next question has just been shown
    const [a] = await db.getAll('attempts')
    expect(a.duration_ms).toBe(8000)
    expect(a.review_ms).toBe(20_000)
    expect(a.synced).toBe(0)
  })

  it('adds up every visit to an answered question, and lets an unanswered one carry its time', async () => {
    const { db, s, advance } = await setup('q1', 'q2', 'q3')
    advance(4000)
    s.next() // q1 skipped for now: 4s on it
    advance(1000)
    s.previous()
    advance(3000)
    s.select(1)
    await s.submit() // 4s + 3s before answering q1
    advance(2000)
    s.next()
    advance(5000)
    s.previous() // back on q1 to read the explanation again
    advance(6000)
    await s.flush()
    const [a] = await db.getAll('attempts')
    expect(a.duration_ms).toBe(7000)
    expect(a.review_ms).toBe(2000 + 6000)
  })

  it('does not count the time the page was hidden', async () => {
    const { db, s, advance } = await setup('q1')
    advance(3000)
    s.setVisible(false)
    advance(600_000)
    s.setVisible(true)
    advance(1000)
    s.select(1)
    await s.submit()
    advance(500)
    s.setVisible(false)
    advance(600_000)
    await s.flush()
    const [a] = await db.getAll('attempts')
    expect(a.duration_ms).toBe(4000)
    expect(a.review_ms).toBe(500)
  })
})

describe('option shuffling', () => {
  const seeded = (seed: number) => () => ((seed = (seed * 16807) % 2147483647) / 2147483647)

  it('shuffles single options but keeps judge options fixed', () => {
    const judge: LocalQuestion = { ...q('j'), type: 'judge', options: ['正确', '错误'], answer: [0] }
    expect(optionOrder(judge, seeded(3))).toEqual([0, 1])
    const orders = new Set<string>()
    for (let seed = 1; seed <= 40; seed++) {
      const o = optionOrder(q('a'), seeded(seed))
      expect([...o].sort()).toEqual([0, 1, 2, 3]) // a permutation, nothing lost
      orders.add(o.join())
    }
    expect(orders.size).toBeGreaterThan(5)
  })

  it('grades and stores original indexes whatever the shown order is', async () => {
    const db = await freshDb()
    const qs = [q('q1'), q('q2')]
    for (const x of qs) await db.put('questions', x)
    // Find a seed whose first question is shown with the right answer (original 1) NOT in position B.
    let seed = 1
    while (optionOrder(q('q1'), seeded(seed))[1] === 1) seed++
    const s = new QuizSession('t', qs, new Repo(db, 'd'), 0, seeded(seed))

    const shown = s.displayOptions
    expect(shown.map((o) => o.text).sort()).toEqual(['丁', '丙', '乙', '甲'])
    const right = shown.findIndex((o) => o.original === 1)
    expect(shown[right].text).toBe('乙')
    s.selectAt(right)
    expect(s.selected).toEqual([1]) // stored as the original index
    expect(s.labelOf(1)).toBe(String.fromCharCode(65 + right))
    await s.submit()
    expect(s.outcome!.correct).toBe(true)
    const [a] = await db.getAll('attempts')
    expect(a.answer).toEqual([1])
  })

  it('keeps the same layout when stepping back', async () => {
    const db = await freshDb()
    const s = new QuizSession('t', [q('q1'), q('q2')], new Repo(db, 'd'), 0, seeded(9))
    const first = s.displayOptions.map((o) => o.original)
    s.select(0)
    await s.submit()
    s.next()
    s.previous()
    expect(s.displayOptions.map((o) => o.original)).toEqual(first)
  })
})
