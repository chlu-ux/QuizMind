import { describe, expect, it } from 'vitest'
import { buildReport, durationParts, formatDuration, formatMinutes, percent } from './stats'
import type { ExamRecord, LocalAttempt, LocalQuestion } from './types'

const q = (id: string, o: Partial<LocalQuestion> = {}): LocalQuestion => ({
  id,
  bank_id: 'b1',
  type: 'single',
  stem: id,
  options: ['A', 'B', 'C', 'D'],
  answer: [1],
  explanation: '',
  difficulty: 2,
  tags: [],
  source_quote: '',
  sync_seq: 1,
  hidden: false,
  ...o,
})

// Local noon, so day arithmetic never lands on a boundary.
const noon = (y: number, m: number, d: number) => new Date(y, m - 1, d, 12).getTime()
const NOW = noon(2026, 10, 3)

let n = 0
const at = (question_id: string, is_correct: boolean, answered_at: number, duration_ms: number | null = 1000): LocalAttempt => ({
  id: `a${++n}`,
  question_id,
  device_id: 'd',
  answer: [0],
  is_correct,
  duration_ms,
  answered_at,
  synced: 1,
})

describe('buildReport', () => {
  it('is empty and has no accuracy before any attempt', () => {
    const r = buildReport([q('a'), q('b')], [], new Set(), NOW)
    expect(r.totalQuestions).toBe(2)
    expect(r.attempts).toBe(0)
    expect(r.accuracy).toBeNull()
    expect(r.answeredQuestions).toBe(0)
    expect(r.streakDays).toBe(0)
    expect(r.weakest).toEqual([])
    expect(r.daily).toHaveLength(7)
    expect(r.daily.at(-1)!.label).toBe('10/3')
    expect(r.daily[0].label).toBe('9/27')
  })

  it('separates attempt accuracy from the latest result per question', () => {
    const qs = [q('a'), q('b'), q('c')]
    const r = buildReport(
      qs,
      [at('a', false, NOW - 3000), at('a', true, NOW - 2000), at('b', false, NOW - 1000)],
      new Set(['b']),
      NOW,
    )
    expect([r.attempts, r.correct, r.accuracy]).toEqual([3, 1, 33])
    expect(r.answeredQuestions).toBe(2)
    expect(r.latestCorrect).toBe(1) // a: last attempt right; b: wrong
    expect(r.wrongBook).toBe(1)
  })

  it('ignores attempts at questions that are not in the list (withdrawn or other banks)', () => {
    const r = buildReport([q('a')], [at('a', true, NOW), at('gone', false, NOW)], new Set(), NOW)
    expect(r.attempts).toBe(1)
    expect(r.accuracy).toBe(100)
  })

  it('groups by type, difficulty and knowledge point, weakest point first', () => {
    const qs = [
      q('a', { difficulty: 1, tags: ['锁', '并发'] }),
      q('b', { difficulty: 3, type: 'judge', tags: ['锁'] }),
    ]
    const r = buildReport(qs, [at('a', true, NOW), at('b', false, NOW), at('b', false, NOW)], new Set(), NOW)
    expect(r.byType.map((g) => [g.label, g.attempts, g.correct])).toEqual([
      ['判断题', 2, 0],
      ['单选题', 1, 1],
    ])
    expect(r.byDifficulty.map((g) => g.label)).toEqual(['难度 1', '难度 3'])
    // 锁: 1 of 3 right; 并发: 1 of 1.
    expect(r.byTag.map((g) => [g.label, percent(g)])).toEqual([
      ['锁', 33],
      ['并发', 100],
    ])
  })

  it('buckets the last 7 days and ignores older attempts there', () => {
    const day = (back: number) => noon(2026, 10, 3 - back)
    const r = buildReport(
      [q('a')],
      [at('a', true, day(0)), at('a', false, day(0)), at('a', true, day(6)), at('a', true, day(7))],
      new Set(),
      NOW,
    )
    expect(r.daily.at(-1)).toMatchObject({ label: '10/3', attempts: 2, correct: 1 })
    expect(r.daily[0]).toMatchObject({ label: '9/27', attempts: 1, correct: 1 })
    expect(r.attempts).toBe(4) // the older one still counts overall
  })

  it('counts the study streak, keeping it alive through a day without practice yet', () => {
    const day = (back: number) => noon(2026, 10, 3 - back)
    const qs = [q('a')]
    const run = (backs: number[]) =>
      buildReport(qs, backs.map((b) => at('a', true, day(b))), new Set(), NOW).streakDays
    expect(run([0, 1, 2, 4])).toBe(3) // gap at day 3
    expect(run([1, 2])).toBe(2) // nothing yet today
    expect(run([2, 3])).toBe(0) // yesterday missed: streak is over
  })

  it('lists the most-missed questions first and caps long study times', () => {
    const qs = [q('a'), q('b'), q('c')]
    const r = buildReport(
      qs,
      [
        at('a', false, NOW, 1000),
        at('a', true, NOW, 1000),
        at('b', false, NOW, 60_000),
        at('b', false, NOW, 10 * 60_000), // left open: counts as 2 minutes
        at('c', true, NOW, null),
      ],
      new Set(),
      NOW,
    )
    expect(r.weakest.map((w) => [w.question.id, w.wrong, w.attempts])).toEqual([
      ['b', 2, 2],
      ['a', 1, 2],
    ])
    expect(r.studyMs).toBe(1000 + 1000 + 60_000 + 120_000)
  })
})

describe('buildReport: practice and study time', () => {
  const withReview = (a: LocalAttempt, review_ms: number | null): LocalAttempt => ({ ...a, review_ms })

  it('splits answering from reading, caps each, and totals both as study time', () => {
    const r = buildReport(
      [q('a'), q('b')],
      [
        withReview(at('a', true, NOW, 30_000), 45_000),
        withReview(at('b', true, NOW, 10 * 60_000), 20 * 60_000), // page left open: 2 min + 3 min
        at('a', true, NOW, 5000), // an older attempt without review time
      ],
      new Set(),
      NOW,
    )
    expect(r.practiceMs).toBe(30_000 + 120_000 + 5000)
    expect(r.reviewMs).toBe(45_000 + 180_000)
    expect(r.studyMs).toBe(r.practiceMs + r.reviewMs)
  })

  it('attributes time to the day of the answer', () => {
    const r = buildReport(
      [q('a')],
      [
        withReview(at('a', true, NOW, 10_000), 5000),
        withReview(at('a', false, NOW - 24 * 3600_000, 20_000), 15_000),
      ],
      new Set(),
      NOW,
    )
    expect(r.daily.map((d) => [d.practiceMs, d.reviewMs]).slice(-2)).toEqual([[20_000, 15_000], [10_000, 5000]])
    expect(r.daily30[0]).toMatchObject({ practiceMs: 0, reviewMs: 0 })
    expect(r.daily30.reduce((n, d) => n + d.practiceMs, 0)).toBe(r.practiceMs)
  })
})

describe('buildReport: longer views and ranking', () => {
  const day = (back: number) => noon(2026, 10, 3 - back)

  it('has a 30-day series whose last 7 entries are the weekly one', () => {
    const r = buildReport([q('a')], [at('a', true, day(0)), at('a', false, day(12)), at('a', true, day(29)), at('a', true, day(30))], new Set(), NOW)
    expect(r.daily30).toHaveLength(30)
    expect(r.daily30.at(-1)).toMatchObject({ label: '10/3', attempts: 1 })
    expect(r.daily30[0]).toMatchObject({ label: '9/4', attempts: 1, correct: 1 })
    expect(r.daily30[17]).toMatchObject({ label: '9/21', attempts: 1, correct: 0 })
    expect(r.daily30.reduce((n, d) => n + d.attempts, 0)).toBe(3) // day 30 is outside the window
    expect(r.daily).toEqual(r.daily30.slice(-7))
  })

  it('turns exam records into a trend, oldest first, latest 20', () => {
    const exam = (i: number, percent: number): ExamRecord => ({
      id: `e${i}`, bank_id: 'b1', title: 't', finished_at: 1000 + i, total: 10, correct: percent / 10, answered: 10,
      percent, passed: percent >= 60, limit_sec: null, used_ms: 1, device_id: 'd', items: [],
    })
    const exams = Array.from({ length: 25 }, (_, i) => exam(i, (i % 10) * 10 + 5)).reverse() // newest first, as Repo returns them
    const r = buildReport([q('a')], [], new Set(), NOW, exams)
    expect(r.examTrend).toHaveLength(20)
    expect(r.examTrend[0].finishedAt).toBe(1005)
    expect(r.examTrend.at(-1)).toMatchObject({ finishedAt: 1024, percent: 45, passed: false })
    expect(buildReport([q('a')], [], new Set(), NOW).examTrend).toEqual([])
  })

  it('does not rank a single miss above a question missed 3 times in 5', () => {
    const qs = [q('once'), q('often'), q('twice')]
    const attempts = [
      at('once', false, NOW - 100),
      ...[false, true, false, true, false].map((ok, i) => at('often', ok, NOW - 90 + i)),
      at('twice', false, NOW - 50),
      at('twice', false, NOW - 49),
    ]
    const r = buildReport(qs, attempts, new Set(), NOW)
    expect(r.weakest.map((w) => [w.question.id, w.wrong, w.attempts])).toEqual([
      ['twice', 2, 2],
      ['often', 3, 5],
      ['once', 1, 1],
    ])
  })

  it('judges weakness by the latest answers only: an old miss that has been fixed drops out', () => {
    const history = [false, false, false, true, true, true, true, true].map((ok, i) => at('a', ok, NOW - 1000 + i))
    expect(buildReport([q('a')], history, new Set(), NOW).weakest).toEqual([])
    const mixed = [true, true, true, true, true, false].map((ok, i) => at('a', ok, NOW - 1000 + i))
    expect(buildReport([q('a')], mixed, new Set(), NOW).weakest.map((w) => [w.wrong, w.attempts])).toEqual([[1, 5]])
  })

  it('folds tag spellings, and in merged view joins related tags', () => {
    const qs = [
      q('a', { tags: ['UML'] }),
      q('b', { tags: ['UML 辨析', 'uml'] }),
      q('c', { tags: ['Cache'] }),
      q('d', { tags: ['cache '] }),
      q('e', { tags: ['OSI'] }),
      q('f', { tags: ['OS'] }),
    ]
    const attempts = qs.map((x, i) => at(x.id, i % 2 === 0, NOW - i))
    const r = buildReport(qs, attempts, new Set(), NOW)
    const names = (g: { label: string }[]) => g.map((x) => x.label.toLowerCase()).sort()
    expect(names(r.byTag)).toEqual(['cache', 'os', 'osi', 'uml', 'uml 辨析'])
    expect(names(r.byTagMerged)).toEqual(['cache', 'os', 'osi', 'uml'])
    // Question b carries two tags that fall in the UML group; it still counts once.
    expect(r.byTagMerged.find((g) => g.label.toLowerCase() === 'uml')!.attempts).toBe(2)
  })
})

describe('formatDuration', () => {
  it('reads naturally', () => {
    expect(formatDuration(20_000)).toBe('不到 1 分钟')
    expect(formatDuration(12 * 60_000)).toBe('12 分钟')
    expect(formatDuration(65 * 60_000)).toBe('1 小时 5 分')
    expect(formatDuration(120 * 60_000)).toBe('2 小时')
  })
})

describe('durationParts / formatMinutes', () => {
  it('splits a duration into figures and units', () => {
    expect(durationParts(0)).toEqual([{ v: '0', u: '分钟' }])
    expect(durationParts(20_000)).toEqual([{ v: '<1', u: '分钟' }])
    expect(durationParts(12 * 60_000)).toEqual([{ v: '12', u: '分钟' }])
    expect(durationParts(65 * 60_000)).toEqual([{ v: '1', u: '小时' }, { v: '5', u: '分' }])
    expect(durationParts(120 * 60_000)).toEqual([{ v: '2', u: '小时' }])
  })
  it('labels a day with whole minutes', () => {
    expect(formatMinutes(0)).toBe('')
    expect(formatMinutes(10_000)).toBe('<1分')
    expect(formatMinutes(12.4 * 60_000)).toBe('12分')
  })
})
