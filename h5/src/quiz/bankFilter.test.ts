// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import type { Bank, LocalQuestion } from '@/data/types'
import { bankOptions, inBank, rememberBank, rememberedBank, UNKNOWN_BANK } from './bankFilter'

const q = (id: string, bank_id: string) => ({ id, bank_id }) as LocalQuestion
const bank = (id: string, title: string) => ({ id, title, description: '', question_count: 0 }) as Bank

describe('bankOptions', () => {
  it('counts questions per bank, in bank order, skipping banks without any', () => {
    const items = [q('1', 'b2'), q('2', 'b1'), q('3', 'b2')]
    const banks = [bank('b1', '甲'), bank('b2', '乙'), bank('b3', '丙')]
    expect(bankOptions(items, banks)).toEqual([
      { id: 'b1', name: '甲', count: 1 },
      { id: 'b2', name: '乙', count: 2 },
    ])
  })

  it('keeps questions of a bank this device no longer lists, under a stand-in name', () => {
    const opts = bankOptions([q('1', 'gone'), q('2', 'b1')], [bank('b1', '甲')])
    expect(opts).toEqual([
      { id: 'b1', name: '甲', count: 1 },
      { id: 'gone', name: UNKNOWN_BANK, count: 1 },
    ])
  })

  it('is empty for an empty list', () => {
    expect(bankOptions([], [bank('b1', '甲')])).toEqual([])
  })
})

describe('inBank', () => {
  const items = [q('1', 'a'), q('2', 'b'), q('3', 'a')]
  it('filters by bank, or returns everything for an empty id', () => {
    expect(inBank(items, 'a').map((x) => x.id)).toEqual(['1', '3'])
    expect(inBank(items, '')).toBe(items)
    expect(inBank(items, 'zzz')).toEqual([])
  })
})

describe('remembered choice', () => {
  it('is kept per list for the session and can be cleared', () => {
    expect(rememberedBank('wrong')).toBe('')
    rememberBank('wrong', 'b1')
    rememberBank('fav', 'b2')
    expect(rememberedBank('wrong')).toBe('b1')
    expect(rememberedBank('fav')).toBe('b2')
    rememberBank('wrong', '')
    expect(rememberedBank('wrong')).toBe('')
    rememberBank('fav', '')
  })
})
