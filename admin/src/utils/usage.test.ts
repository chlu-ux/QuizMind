import { describe, expect, it } from 'vitest'
import type { UsageRow } from '@/api/types'
import { agentSourceLabel, callSubject, cacheRate, dayKey, filterRows, firstDay, todayAndMonth, totalsOf } from './usage'

const row = (over: Partial<UsageRow>): UsageRow => ({
  day: '2026-10-08', source: 'server', role: 'generator', model: 'm', calls: 1,
  input_tokens: 100, output_tokens: 50, cached_tokens: 0, failures: 0, estimated_calls: 0, ...over,
})

const now = new Date(2026, 9, 8, 15, 0) // 8 Oct 2026, local

describe('usage helpers', () => {
  it('labels days in local time, today counting as the first of N', () => {
    expect(dayKey(now)).toBe('2026-10-08')
    expect(firstDay(1, now)).toBe('2026-10-08')
    expect(firstDay(7, now)).toBe('2026-10-02')
    expect(firstDay(10, now)).toBe('2026-09-29') // crosses a month boundary
  })

  it('filters by range, source and role', () => {
    const rows = [
      row({ day: '2026-10-08' }),
      row({ day: '2026-10-01', source: 'client', role: 'explain' }),
      row({ day: '2026-09-01', role: 'agent' }),
    ]
    expect(filterRows(rows, { days: 7, source: '', role: '' }, now)).toHaveLength(1)
    expect(filterRows(rows, { days: 30, source: '', role: '' }, now)).toHaveLength(2)
    expect(filterRows(rows, { days: 90, source: 'client', role: '' }, now)).toHaveLength(1)
    expect(filterRows(rows, { days: 90, source: '', role: 'agent' }, now)).toHaveLength(1)
    expect(filterRows(rows, { days: 0, source: '', role: '' }, now)).toHaveLength(3)
  })

  it('sums calls, tokens, failures and guessed calls', () => {
    const t = totalsOf([row({ calls: 2, failures: 1 }), row({ source: 'client', estimated_calls: 3, cached_tokens: 40 })])
    expect(t).toEqual({ calls: 3, input: 200, output: 100, cached: 40, failures: 1, estimated: 3 })
  })

  it('totals today and this month, not other months', () => {
    const rows = [row({}), row({ day: '2026-10-03' }), row({ day: '2026-09-30', input_tokens: 9999 })]
    expect(todayAndMonth(rows, now)).toEqual({ today: 150, month: 300 })
  })

  it('computes the cache hit rate without dividing by zero', () => {
    expect(cacheRate(totalsOf([]))).toBe(0)
    expect(cacheRate(totalsOf([row({ input_tokens: 300, cached_tokens: 100 })]))).toBe(25)
  })
})

describe('callSubject', () => {
  const base = { role: 'explain' as const, question_id: '', question_stem: '', job_id: '' }

  it('names the conversation of an assistant call, since there is no question behind it', () => {
    expect(callSubject({ ...base, role: 'agent', question_id: '01JABCDEF123456' })).toEqual({ kind: 'conversation', label: '对话 123456' })
  })

  it('shows the question for the others, then the job, then nothing', () => {
    expect(callSubject({ ...base, question_id: 'q1', question_stem: '读写锁？' })).toEqual({ kind: 'question', label: '读写锁？' })
    expect(callSubject({ ...base, role: 'generator', job_id: '01JOB000999' })).toEqual({ kind: 'job', label: '任务 000999' })
    expect(callSubject(base)).toEqual({ kind: 'none', label: '-' })
  })

  it('an assistant call without a conversation falls through like any other', () => {
    expect(callSubject({ ...base, role: 'agent' })).toEqual({ kind: 'none', label: '-' })
  })
})

describe('agentSourceLabel', () => {
  it('says which conversation wrote the question and whether a second model checked it', () => {
    expect(agentSourceLabel({ conversation_id: '01JCONV123456', verified: true })).toBe('助手草稿 · 对话 123456 · 经独立复核')
    expect(agentSourceLabel({ conversation_id: '01JCONV123456', verified: false })).toBe('助手草稿 · 对话 123456 · 未经独立复核')
  })
})
