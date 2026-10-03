import { describe, expect, it, vi } from 'vitest'
import { reactive } from 'vue'
import { freshDb } from '@/test-support'
import { Repo } from '@/data/repo'
import type { LocalQuestion } from '@/data/types'
import { drawExam, drawPaper, examCountChoices, ExamSession, paperPool, paperTags, PASS_PERCENT } from './exam'

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
    expect(r.entries.map((i) => i.correct)).toEqual([true, false, false, true])
    expect(r.entries[2].selected).toEqual([])

    const attempts = (await db.getAll('attempts')).sort((a, b) => a.question_id.localeCompare(b.question_id))
    expect(attempts.map((a) => [a.question_id, a.is_correct, a.duration_ms])).toEqual([
      ['q1', true, 5000],
      ['q2', false, 7000],
      ['q4', true, 3000],
    ])
    expect((await repo.wrongBook()).map((x) => x.id)).toEqual(['q2']) // exam misses feed the wrong book
    const [saved] = await repo.exams('b1')
    expect(saved).toMatchObject({ id: r.id, total: 4, correct: 2, percent: 50, passed: false })
    expect(saved.items).toEqual([
      { q: 'q1', s: [1], c: true },
      { q: 'q2', s: [0], c: false },
      { q: 'q3', s: [], c: false },
      { q: 'q4', s: [1], c: true },
    ])
    expect(saved.device_id).toBe('d')
    expect((await db.get('exams', r.id))!.synced).toBe(0) // waiting for upload
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

const withTags = (id: string, tags: string[], o: Partial<LocalQuestion> = {}) => q(id, { tags, ...o })

// A deterministic stand-in for Math.random.
function lcg(seed = 1) {
  let a = seed
  return () => {
    a = (a * 1664525 + 1013904223) % 4294967296
    return a / 4294967296
  }
}

describe('paper building', () => {
  const bank = [
    withTags('a1', ['UML'], { difficulty: 1 }),
    withTags('a2', ['UML 辨析'], { difficulty: 2 }),
    withTags('a3', ['范式'], { difficulty: 3 }),
    withTags('a4', ['范式', 'SQL'], { difficulty: 3 }),
    withTags('a5', ['SQL'], { difficulty: 4 }),
    withTags('a6', ['SQL'], { difficulty: 5 }),
  ]

  it('limits the pool to the chosen knowledge points, merged tags included', () => {
    const tags = paperTags(bank)
    expect(tags[0]).toEqual({ label: 'SQL', count: 3 })
    expect(tags.slice(1).map((t) => [t.label, t.count]).sort()).toEqual([['UML', 2], ['范式', 2]])
    expect(paperPool(bank, []).map((x) => x.id)).toEqual(['a1', 'a2', 'a3', 'a4', 'a5', 'a6'])
    expect(paperPool(bank, ['UML']).map((x) => x.id)).toEqual(['a1', 'a2'])
    expect(paperPool(bank, ['UML', '范式']).map((x) => x.id)).toEqual(['a1', 'a2', 'a3', 'a4'])
  })

  it('random draws only from the pool and never repeats', () => {
    const got = drawPaper(bank, 10, { strategy: 'random', tags: ['SQL'] }, lcg())
    expect(got.map((x) => x.id).sort()).toEqual(['a4', 'a5', 'a6'])
  })

  it('weak mode takes last-wrong and wrong-book questions first, then untried, then the rest', () => {
    const history = new Map([
      ['a1', { attempts: 2, lastCorrect: true }], // done and right
      ['a2', { attempts: 1, lastCorrect: false }], // last wrong
      ['a3', { attempts: 3, lastCorrect: true }], // right now, but still in the wrong book
    ])
    const opts = { strategy: 'weak' as const, history, wrongIds: new Set(['a3']) }
    for (const seed of [1, 2, 3]) {
      expect(new Set(drawPaper(bank, 2, opts, lcg(seed)).map((x) => x.id))).toEqual(new Set(['a2', 'a3']))
      // Next come the untried ones (a4-a6), never the finished-and-right a1.
      const four = new Set(drawPaper(bank, 4, opts, lcg(seed)).map((x) => x.id))
      expect(four.has('a1')).toBe(false)
      expect(four.has('a2') && four.has('a3')).toBe(true)
    }
    expect(drawPaper(bank, 6, opts, lcg()).map((x) => x.id).sort()).toHaveLength(6)
  })

  it('balanced mode mixes easy, medium and hard about 4:4:2 and tops up from what is left', () => {
    const big = Array.from({ length: 30 }, (_, i) => q(`e${i}`, { difficulty: 1 }))
      .concat(Array.from({ length: 30 }, (_, i) => q(`m${i}`, { difficulty: 3 })))
      .concat(Array.from({ length: 30 }, (_, i) => q(`h${i}`, { difficulty: 5 })))
    const got = drawPaper(big, 10, { strategy: 'balanced' }, lcg())
    const by = (p: string) => got.filter((x) => x.id.startsWith(p)).length
    expect([by('e'), by('m'), by('h')]).toEqual([4, 4, 2])

    // Only 1 hard question exists: the shortfall comes from the others.
    const few = big.filter((x) => !x.id.startsWith('h') || x.id === 'h0')
    const got2 = drawPaper(few, 10, { strategy: 'balanced' }, lcg())
    expect(got2).toHaveLength(10)
    expect(new Set(got2.map((x) => x.id)).size).toBe(10)
    expect(got2.filter((x) => x.id.startsWith('h'))).toHaveLength(1)
  })
})

describe('exam in progress', () => {
  it('saves after every change and is gone once handed in', async () => {
    const { db, repo, exam, clock } = await setup(['q1', 'q2', 'q3'], 600)
    exam.save()
    await Promise.resolve()
    exam.select(1)
    clock.t += 4000
    exam.go(2)
    exam.toggleMark()
    await new Promise((r) => setTimeout(r, 20))
    const draft = (await repo.examDraft('b1'))!
    expect(draft).toMatchObject({ ids: ['q1', 'q2', 'q3'], index: 2, limit_sec: 600, started_at: 1_000_000 })
    expect(draft.answers).toEqual({ q1: [1] })
    expect(draft.marked).toEqual(['q3'])
    expect(draft.spent.q1).toBe(4000)

    await exam.submit()
    expect(await db.count('examDrafts')).toBe(0)
  })

  it('restores answers, marks, position and the running clock', async () => {
    const { repo, exam, clock } = await setup(['q1', 'q2', 'q3'], 600)
    exam.select(1)
    clock.t += 90_000
    exam.go(1)
    exam.toggleMark()
    const draft = exam.snapshot()

    clock.t += 30_000 // away for 30 s
    const back = ExamSession.restore(draft, [q('q1'), q('q2'), q('q3')], repo, () => clock.t)!
    expect(back.index).toBe(1)
    expect(back.isAnswered(0)).toBe(true)
    expect(back.isMarked(1)).toBe(true)
    expect(back.remainingSec()).toBe(600 - 120) // 90 s + 30 s since the original start
    expect(back.seed).toBe(exam.seed)
    expect(back.displayOptions.map((o) => o.original)).toEqual(exam.displayOptions.map((o) => o.original))

    back.go(2)
    back.select(1)
    const r = await back.submit()
    expect([r.correct, r.answered]).toEqual([2, 2])
    expect(r.used_ms).toBe(120_000) // timed: wall clock since the start
  })

  it('drops withdrawn questions on restore without reshuffling the others', async () => {
    const { repo, exam } = await setup(['q1', 'q2', 'q3'])
    exam.go(2)
    exam.select(1)
    const draft = exam.snapshot()
    const full = ExamSession.restore(draft, [q('q1'), q('q2'), q('q3')], repo)!
    const some = ExamSession.restore(draft, [q('q1'), q('q3')], repo)! // q2 withdrawn
    expect(some.questions.map((x) => x.id)).toEqual(['q1', 'q3'])
    expect(some.current.id).toBe('q3')
    expect(some.selected).toEqual([1])
    some.go(1)
    full.go(2)
    expect(some.displayOptions.map((o) => o.original)).toEqual(full.displayOptions.map((o) => o.original))
    expect(ExamSession.restore(draft, [], repo)).toBeNull()
  })

  it('counts only active time for an untimed exam', async () => {
    const { repo, exam, clock } = await setup(['q1', 'q2'])
    exam.select(1)
    clock.t += 10_000
    const draft = exam.snapshot()
    clock.t += 3_600_000 // an hour away
    const back = ExamSession.restore(draft, [q('q1'), q('q2')], repo, () => clock.t)!
    clock.t += 5_000
    const r = await back.submit()
    expect(r.used_ms).toBe(15_000)
  })

  it('marks toggle and are locked after hand-in', async () => {
    const { exam } = await setup(['q1', 'q2'])
    expect(exam.markedCount).toBe(0)
    exam.toggleMark()
    expect(exam.markedCount).toBe(1)
    exam.toggleMark()
    expect(exam.isMarked(0)).toBe(false)
    await exam.submit()
    exam.toggleMark()
    expect(exam.markedCount).toBe(0)
  })

  it('handing in is all or nothing: a failure leaves no attempts, exam or lost draft, and a retry works', async () => {
    const { db, repo, exam } = await setup(['q1', 'q2', 'q3'])
    exam.select(1)
    exam.go(1)
    exam.select(0)
    exam.save()
    await new Promise((r) => setTimeout(r, 20))
    expect(await db.count('examDrafts')).toBe(1)

    // Make the hand-in fail after the answers were written, while storing the result (a plain exception, not a request error).
    const stringify = JSON.stringify
    let broken = true
    vi.spyOn(JSON, 'stringify').mockImplementation(((v: unknown, ...rest: never[]) => {
      if (broken && typeof v === 'object' && v !== null && 'synced' in v && 'items' in v) throw new Error('disk full')
      return stringify(v, ...rest)
    }) as never)

    await expect(exam.submit()).rejects.toThrow('disk full')
    expect(await db.count('attempts')).toBe(0)
    expect(await db.count('exams')).toBe(0)
    expect(await db.count('states')).toBe(0)
    expect(await db.count('examDrafts')).toBe(1)
    expect(exam.submitted).toBe(false)

    broken = false
    const r = await exam.submit()
    expect(r.answered).toBe(2)
    expect(await db.count('attempts')).toBe(2)
    expect(await db.count('exams')).toBe(1)
    expect(await db.count('examDrafts')).toBe(0)
    expect((await repo.exams('b1'))).toHaveLength(1)
    vi.restoreAllMocks()
  })
})
