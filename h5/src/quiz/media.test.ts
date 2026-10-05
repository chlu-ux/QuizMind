// @vitest-environment happy-dom
import { mount } from '@vue/test-utils'
import { describe, expect, it } from 'vitest'
import Md from '@/components/Md.vue'
import OptText from '@/components/OptText.vue'
import { lightbox } from '@/core/lightbox'
import { mediaUrl, plainText, segments } from './media'
import { searchQuestions } from './search'
import type { LocalQuestion } from '@/data/types'

const ID = '0123456789abcdef01234567'

describe('media references', () => {
  it('points media: at the API and leaves other addresses alone', () => {
    expect(mediaUrl(`media:${ID}`)).toBe(`/api/v1/media/${ID}`)
    expect(mediaUrl(`media:${ID}`, 'http://h:8080')).toBe(`http://h:8080/api/v1/media/${ID}`)
    expect(mediaUrl('https://x.test/a.png')).toBe('https://x.test/a.png')
    expect(mediaUrl('media:nope')).toBe('media:nope')
  })

  it('shows a placeholder where lists have no room for a picture', () => {
    expect(plainText(`如图所示的类图\n\n![](media:${ID})`)).toBe('如图所示的类图\n\n[图]')
    expect(plainText(`![用例图](media:${ID}) 与 ![](media:${ID})`)).toBe('[图：用例图] 与 [图]')
    expect(plainText('![x](https://other.test/a.png)')).toBe('![x](https://other.test/a.png)')
  })

  it('splits an option into text and pictures without interpreting other Markdown', () => {
    expect(segments('*p++ 与 <T>')).toEqual([{ kind: 'text', text: '*p++ 与 <T>' }])
    expect(segments(`A ![图](media:${ID}) B`)).toEqual([
      { kind: 'text', text: 'A ' },
      { kind: 'image', src: `/api/v1/media/${ID}`, alt: '图' },
      { kind: 'text', text: ' B' },
    ])
  })
})

describe('rendering', () => {
  it('renders a picture in a stem and opens it full size on tap', async () => {
    const w = mount(Md, { props: { source: `看图回答\n\n![类图](media:${ID})` } })
    const img = w.get('img.qimg')
    expect(img.attributes('src')).toBe(`/api/v1/media/${ID}`)
    expect(img.attributes('alt')).toBe('类图')
    await img.trigger('click')
    expect(lightbox.src).toContain(`/api/v1/media/${ID}`)
    lightbox.src = ''
  })

  it('keeps raw HTML out of a stem', () => {
    const w = mount(Md, { props: { source: '<img src=x onerror=alert(1)>' } })
    expect(w.find('img').exists()).toBe(false)
  })

  it('renders a picture inside an option', () => {
    const w = mount(OptText, { props: { text: `![](media:${ID})` } })
    expect(w.get('img').attributes('src')).toBe(`/api/v1/media/${ID}`)
  })
})

describe('search', () => {
  it('does not match the picture id', () => {
    const q = { id: 'q', stem: `如图\n![](media:${ID})`, options: ['a', 'b', 'c', 'd'], tags: [], explanation: '' } as unknown as LocalQuestion
    expect(searchQuestions([q], 'abcdef')).toHaveLength(0)
    expect(searchQuestions([q], '如图')).toHaveLength(1)
  })
})
