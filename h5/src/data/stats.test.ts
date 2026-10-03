import { describe, expect, it } from 'vitest'
import { buildReport, formatDuration, percent } from './stats'
import type { LocalAttempt, LocalQuestion } from './types'

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

describe('formatDuration', () => {
  it('reads naturally', () => {
    expect(formatDuration(20_000)).toBe('不到 1 分钟')
    expect(formatDuration(12 * 60_000)).toBe('12 分钟')
    expect(formatDuration(65 * 60_000)).toBe('1 小时 5 分')
    expect(formatDuration(120 * 60_000)).toBe('2 小时')
  })
})
