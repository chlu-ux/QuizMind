import { describe, expect, it } from 'vitest'
import { findQuote, splitByRange } from './highlight'

describe('findQuote', () => {
  const text = '读写锁允许多个读者同时持有锁，但写者必须独占。**互斥锁**保证同一时刻只有一个线程进入临界区。'

  it('finds an exact quote', () => {
    const r = findQuote(text, '读写锁允许多个读者同时持有锁')
    expect(r).not.toBeNull()
    expect(text.slice(r!.start, r!.end)).toBe('读写锁允许多个读者同时持有锁')
  })

  it('ignores markdown markup and punctuation differences', () => {
    const r = findQuote(text, '互斥锁保证同一时刻只有一个线程进入临界区。')
    expect(r).not.toBeNull()
    const hit = text.slice(r!.start, r!.end)
    expect(hit.startsWith('互斥锁')).toBe(true)
    expect(hit.endsWith('临界区')).toBe(true)
  })

  it('maps through markup inside the quote', () => {
    const r = findQuote('前面 **加粗的词** 后面', '加粗的词后面')
    expect(r).not.toBeNull()
  })

  it('is case- and width-insensitive', () => {
    const r = findQuote('Use SYNC.Mutex here', 'sync mutex')
    expect(r).not.toBeNull()
    const full = findQuote('ＡＢＣ中文', 'abc中文')
    expect(full).not.toBeNull()
  })

  it('returns null when the quote is absent or empty', () => {
    expect(findQuote(text, '这句话不在原文里')).toBeNull()
    expect(findQuote(text, '，。！')).toBeNull()
  })

  it('handles astral characters without cutting them in half', () => {
    const t = '开头😀结尾内容'
    const r = findQuote(t, '结尾内容')
    expect(t.slice(r!.start, r!.end)).toBe('结尾内容')
  })
})

describe('splitByRange', () => {
  it('splits into before / mark / after', () => {
    expect(splitByRange('abcdef', { start: 2, end: 4 })).toEqual([
      { text: 'ab', mark: false },
      { text: 'cd', mark: true },
      { text: 'ef', mark: false },
    ])
  })
  it('returns whole text when there is no range', () => {
    expect(splitByRange('abc', null)).toEqual([{ text: 'abc', mark: false }])
  })
  it('drops empty segments at the edges', () => {
    expect(splitByRange('abc', { start: 0, end: 3 })).toEqual([{ text: 'abc', mark: true }])
  })
})
