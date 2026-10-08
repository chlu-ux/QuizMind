import { describe, expect, it } from 'vitest'
import { checkSvg, splitSvg, svgDataUrl } from './svg'

const ns = 'xmlns="http://www.w3.org/2000/svg"'
const good = `<svg ${ns} viewBox="0 0 100 50"><defs><marker id="a"><path d="M0 0L5 5"/></marker></defs><rect x="1" y="1" width="40" height="20"/><text x="5" y="15">类</text><line x1="0" y1="0" x2="9" y2="9" marker-end="url(#a)"/></svg>`

describe('splitSvg', () => {
  it('cuts a complete svg out of the text, with or without its fence', () => {
    expect(splitSvg(`看图：\n\`\`\`svg\n${good}\n\`\`\`\n以上`)).toEqual([
      { text: '看图：\n', svg: false },
      { text: good, svg: true },
      { text: '\n以上', svg: false },
    ])
    expect(splitSvg(`图 ${good} 完`).map((p) => p.svg)).toEqual([false, true, false])
  })

  it('leaves a diagram that is still being written as text', () => {
    const half = `<svg ${ns}><rect width="4"`
    expect(splitSvg(half)).toEqual([{ text: half, svg: false }])
  })

  it('leaves svg shown as an example inside another code block alone', () => {
    const t = `例子：\n\`\`\`js\nconst s = \`${good}\`\n\`\`\`\n`
    expect(splitSvg(t).every((p) => !p.svg)).toBe(true)
  })
})

describe('checkSvg', () => {
  it('lets a plain drawing through', () => {
    expect(checkSvg(good)).toBe(good)
    expect(checkSvg(`  ${good}\n`)).toBe(good)
  })

  it('adds the namespace models forget, but refuses a different one', () => {
    const bare = '<svg viewBox="0 0 9 9"><circle r="3"/></svg>'
    expect(checkSvg(bare)).toBe(`<svg ${ns} viewBox="0 0 9 9"><circle r="3"/></svg>`)
    expect(checkSvg('<svg xmlns="http://example.com/x"><circle r="3"/></svg>')).toBeNull()
  })

  it.each([
    ['script', `<svg ${ns}><script>alert(1)</script></svg>`],
    ['style', `<svg ${ns}><style>@import url(http://x/y.css)</style></svg>`],
    ['foreignObject', `<svg ${ns}><foreignObject><div/></foreignObject></svg>`],
    ['image', `<svg ${ns}><image href="http://x/a.png"/></svg>`],
    ['link', `<svg ${ns}><a href="http://x"><rect/></a></svg>`],
    ['event handler', `<svg ${ns} onload="x()"><rect/></svg>`],
    ['event handler in a child', `<svg ${ns}><rect onclick="x()"/></svg>`],
    ['outside href', `<svg ${ns}><use href="http://x/a.svg#b"/></svg>`],
    ['outside url()', `<svg ${ns}><rect fill="url(http://x/a.svg#b)"/></svg>`],
    ['javascript:', `<svg ${ns}><rect title="javascript:x()"/></svg>`],
    ['data:', `<svg ${ns}><rect title="data:text/html,x"/></svg>`],
    ['doctype', `<svg ${ns}><!DOCTYPE x [<!ENTITY a "b">]><rect/></svg>`],
    ['cdata', `<svg ${ns}><![CDATA[<script>]]></svg>`],
    ['unbalanced', `<svg ${ns}><g><rect/></svg>`],
    ['not svg at the root', `<div ${ns}><rect/></div></svg>`],
    ['too big', `<svg ${ns}><text>${'a'.repeat(60001)}</text></svg>`],
    ['nested too deep', `<svg ${ns}>${'<g>'.repeat(70)}${'</g>'.repeat(70)}</svg>`],
  ])('refuses %s', (_, svg) => {
    expect(checkSvg(svg)).toBeNull()
  })

  it('allows a reference inside the drawing, a comment, and ">" in text', () => {
    const ok = `<svg ${ns}><!-- 注释 --><defs><linearGradient id="g"><stop offset="0"/></linearGradient></defs><use href="#g"/><rect fill="url(#g)"/><text>a > b</text></svg>`
    expect(checkSvg(ok)).toBe(ok)
  })
})

describe('svgDataUrl', () => {
  it('encodes the drawing so it survives as an image source', () => {
    const url = svgDataUrl(good)
    expect(url.startsWith('data:image/svg+xml;charset=utf-8,')).toBe(true)
    expect(decodeURIComponent(url.split(',').slice(1).join(','))).toBe(good)
  })
})
