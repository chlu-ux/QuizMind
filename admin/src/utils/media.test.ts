import { describe, expect, it } from 'vitest'
import { isPlainSvg, mediaUrl, plainText, segments, svgDataUri, withMediaUrls } from './media'

const ID = '0123456789abcdef01234567'

describe('media references', () => {
  it('points media: addresses at the API and leaves other images alone', () => {
    expect(withMediaUrls(`看图\n\n![类图](media:${ID})`)).toBe(`看图\n\n![类图](${mediaUrl(ID)})`)
    expect(withMediaUrls('![x](https://other.test/a.png)')).toBe('![x](https://other.test/a.png)')
    expect(withMediaUrls('![x](media:short)')).toBe('![x](media:short)')
  })

  it('summarises a picture in one-line lists', () => {
    expect(plainText(`如图 ![](media:${ID})`)).toBe('如图 [图]')
    expect(plainText(`![用例图](media:${ID})`)).toBe('[图：用例图]')
  })

  it('splits an option into text and pictures without interpreting other Markdown', () => {
    expect(segments('*p++')).toEqual([{ kind: 'text', text: '*p++' }])
    expect(segments(`![图](media:${ID}) 对`)).toEqual([
      { kind: 'image', src: mediaUrl(ID), alt: '图' },
      { kind: 'text', text: ' 对' },
    ])
  })
})

describe('AI diagrams', () => {
  const svg = '<svg viewBox="0 0 10 10"><rect width="10" height="10"/></svg>'

  it('accepts a small plain SVG and turns it into an image address', () => {
    expect(isPlainSvg(svg)).toBe(true)
    expect(svgDataUri(` ${svg}\n`)).toBe(`data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`)
  })

  it('refuses scripts, embedded foreign content, external images and anything that is not an SVG', () => {
    expect(isPlainSvg('<svg><script>alert(1)</script></svg>')).toBe(false)
    expect(isPlainSvg('<svg><foreignObject><div/></foreignObject></svg>')).toBe(false)
    expect(isPlainSvg('<svg><image href="https://x.test/a.png"/></svg>')).toBe(false)
    expect(isPlainSvg('<div>hi</div>')).toBe(false)
    expect(isPlainSvg(`<svg>${'x'.repeat(60_000)}</svg>`)).toBe(false)
  })
})
