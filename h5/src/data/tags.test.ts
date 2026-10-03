import { describe, expect, it } from 'vitest'
import { normalizeTag, tagLabeler } from './tags'

describe('normalizeTag', () => {
  it('folds width and whitespace', () => {
    expect(normalizeTag('  ＵＭＬ   类图 ')).toBe('UML 类图')
  })
})

describe('tagLabeler', () => {
  const tags = ['UML', 'UML 辨析', 'UML', 'uml', 'Cache', 'cache', 'OS', 'OSI', '数据流图', '数据流图案例', '图', '图论', '数据库/范式', '数据库']

  it('without merging, only spelling variants share a label (the most common spelling wins)', () => {
    const l = tagLabeler(tags, false)
    expect(l('uml')).toBe('UML')
    expect(l('Cache')).toBe(l('cache'))
    expect(l('UML 辨析')).toBe('UML 辨析')
    expect(l('数据流图案例')).toBe('数据流图案例')
  })

  it('merging joins a tag to the shorter tag it starts with', () => {
    const l = tagLabeler(tags, true)
    expect(l('UML 辨析')).toBe('UML')
    expect(l('数据流图案例')).toBe('数据流图')
    expect(l('数据库/范式')).toBe('数据库')
  })

  it('never merges on a one-letter prefix or in the middle of a Latin word', () => {
    const l = tagLabeler(tags, true)
    expect(l('图论')).toBe('图论')
    expect(l('OSI')).toBe('OSI')
    expect(l('OS')).toBe('OS')
  })

  it('leaves unknown tags alone and tolerates empty input', () => {
    expect(tagLabeler([], true)('随便')).toBe('随便')
    expect(tagLabeler(['', '  '], false)('')).toBe('')
  })
})
