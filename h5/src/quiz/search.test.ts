import { describe, expect, it } from 'vitest'
import type { LocalQuestion } from '@/data/types'
import { highlight, searchQuestions, searchTerms } from './search'

const q = (id: string, o: Partial<LocalQuestion> = {}): LocalQuestion => ({
  id,
  bank_id: 'b',
  type: 'single',
  stem: `题干 ${id}`,
  options: ['甲', '乙', '丙', '丁'],
  answer: [0],
  explanation: '',
  difficulty: 2,
  tags: [],
  source_quote: '',
  sync_seq: 1,
  hidden: false,
  ...o,
})

const ids = (qs: LocalQuestion[], query: string) => searchQuestions(qs, query).map((h) => h.question.id)

describe('searchTerms', () => {
  it('folds case and width, splits on any whitespace and drops duplicates', () => {
    expect(searchTerms('  ＵＭＬ　图\t uml ')).toEqual(['uml', '图'])
    expect(searchTerms('   ')).toEqual([])
    expect(searchTerms('')).toEqual([])
  })
})

describe('searchQuestions', () => {
  const qs = [
    q('a', { stem: '读写锁允许多个读者同时持有锁' }),
    q('b', { stem: '互斥锁只允许一个线程持有', explanation: '与读写锁相比，互斥锁更简单' }),
    q('c', { stem: '下列哪项正确', options: ['使用读写锁', '使用信号量', '不加锁', '随便'] }),
  ]

  it('needs every word, in any field', () => {
    expect(ids(qs, '读写锁')).toEqual(['a', 'c', 'b'])
    expect(ids(qs, '读写锁 互斥锁')).toEqual(['b'])
    expect(ids(qs, '读写锁 信号量')).toEqual(['c'])
    expect(ids(qs, '读写锁 不存在')).toEqual([])
  })

  it('ignores case, width and extra spaces', () => {
    const list = [q('x', { stem: 'UML 类图的画法' }), q('y', { stem: '数据流图' })]
    expect(ids(list, 'uml')).toEqual(['x'])
    expect(ids(list, 'ＵＭＬ  类图')).toEqual(['x'])
    expect(ids([q('z', { stem: '版本１０的特性' })], '版本10')).toEqual(['z'])
  })

  it('blank queries find nothing and withdrawn questions never show', () => {
    expect(ids(qs, '')).toEqual([])
    expect(ids(qs, '   ')).toEqual([])
    expect(ids([q('h', { stem: '读写锁', hidden: true })], '读写锁')).toEqual([])
  })

  it('ranks stem hits before option and tag hits before explanation hits, keeping bank order within a level', () => {
    const list = [
      q('expl', { stem: '无关', explanation: '这里讲到缓存一致性' }),
      q('opt', { stem: '无关', options: ['缓存', 'b', 'c', 'd'] }),
      q('stem1', { stem: '缓存的作用' }),
      q('tag', { stem: '无关', tags: ['缓存'] }),
      q('stem2', { stem: '什么是缓存' }),
    ]
    const hits = searchQuestions(list, '缓存')
    expect(hits.map((h) => h.question.id)).toEqual(['stem1', 'stem2', 'opt', 'tag', 'expl'])
    expect(hits.map((h) => h.where)).toEqual(['stem', 'stem', 'option', 'tag', 'explanation'])
  })

  it('says what matched when it is not the stem', () => {
    const list = [
      q('opt', { stem: '无关', options: ['先进先出', '最近最少使用', 'c', 'd'] }),
      q('tag', { stem: '无关', tags: ['LRU 算法'] }),
      q('stem', { stem: '最近最少使用是什么' }),
    ]
    expect(ids(list, '最近最少使用 lru')).toEqual([]) // no single question has both words
    const one = searchQuestions(list, '最近最少')
    expect(one.map((h) => [h.question.id, h.snippet])).toEqual([
      ['stem', ''],
      ['opt', '最近最少使用'],
    ])
    expect(searchQuestions(list, 'lru')[0].snippet).toBe('LRU 算法')
  })

  it('shows a window around the hit for a long explanation', () => {
    const long = '前面是很长很长的一段铺垫文字，用来把命中的词挤到中间去。' + '关键词出现在这里' + '。后面还有很长很长的一段说明文字，同样是为了超出窗口，继续往后写，再多写几句凑够字数，确保明显超过后面保留的那一段上下文。'
    const [h] = searchQuestions([q('e', { stem: '无关', explanation: long })], '关键词')
    expect(h.where).toBe('explanation')
    expect(h.snippet.startsWith('…')).toBe(true)
    expect(h.snippet.endsWith('…')).toBe(true)
    expect(h.snippet).toContain('关键词出现在这里')
    expect(h.snippet.length).toBeLessThan(long.length)
  })

  it('treats regular-expression characters literally', () => {
    const list = [q('a', { stem: '计算 (a+b)*c 的值' }), q('b', { stem: 'abc' })]
    expect(ids(list, '(a+b)*c')).toEqual(['a'])
    expect(ids(list, '.*')).toEqual([])
    expect(ids(list, '[')).toEqual([])
  })
})

describe('highlight', () => {
  const joined = (p: { text: string }[]) => p.map((x) => x.text).join('')

  it('marks every occurrence and joins back into the original', () => {
    const p = highlight('读写锁和互斥锁都是锁', ['锁'])
    expect(joined(p)).toBe('读写锁和互斥锁都是锁')
    expect(p.filter((x) => x.hit).map((x) => x.text)).toEqual(['锁', '锁', '锁'])
    expect(p.every((x) => x.text.length > 0)).toBe(true)
  })

  it('merges overlapping and touching terms', () => {
    expect(highlight('abcdef', ['abc', 'cde'])).toEqual([
      { text: 'abcde', hit: true },
      { text: 'f', hit: false },
    ])
    expect(highlight('abcd', ['ab', 'cd'])).toEqual([{ text: 'abcd', hit: true }])
  })

  it('handles a hit at the very start, at the very end, and none at all', () => {
    expect(highlight('锁定', ['锁'])).toEqual([
      { text: '锁', hit: true },
      { text: '定', hit: false },
    ])
    expect(highlight('加锁', ['锁'])).toEqual([
      { text: '加', hit: false },
      { text: '锁', hit: true },
    ])
    expect(highlight('加锁', ['x'])).toEqual([{ text: '加锁', hit: false }])
    expect(highlight('', ['x'])).toEqual([])
    expect(highlight('abc', [])).toEqual([{ text: 'abc', hit: false }])
  })

  it('matches case and width loosely but returns the original text', () => {
    expect(highlight('Use UML 图', ['uml'])).toEqual([
      { text: 'Use ', hit: false },
      { text: 'UML', hit: true },
      { text: ' 图', hit: false },
    ])
    expect(highlight('ＵＭＬ图', ['uml'])).toEqual([
      { text: 'ＵＭＬ', hit: true },
      { text: '图', hit: false },
    ])
  })

  it('never reads terms as patterns', () => {
    expect(highlight('a.b a+b', ['.', '+'])).toEqual([
      { text: 'a', hit: false },
      { text: '.', hit: true },
      { text: 'b a', hit: false },
      { text: '+', hit: true },
      { text: 'b', hit: false },
    ])
  })

  it('keeps surrogate pairs whole', () => {
    expect(highlight('A😀B', ['😀'])).toEqual([
      { text: 'A', hit: false },
      { text: '😀', hit: true },
      { text: 'B', hit: false },
    ])
  })
})
