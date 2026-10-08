// Diagrams the assistant draws as SVG in its answers (docs/agent-design.md §8).
//
// An SVG shown through <img> never runs script, so the check below is the second line of defence: it
// keeps to the same whitelist as the server's checkSVG (server/internal/service/svg.go), and what
// does not pass is shown as code instead.

const SVG_NS = 'http://www.w3.org/2000/svg'
const MAX_CHARS = 60000
const MAX_DEPTH = 64

const ELEMENTS = new Set([
  'svg', 'g', 'defs', 'title', 'desc',
  'rect', 'circle', 'ellipse', 'line', 'polyline', 'polygon', 'path',
  'text', 'tspan', 'marker', 'clipPath',
  'linearGradient', 'radialGradient', 'stop', 'use',
])

// An `<svg>` element (group 1), with the fence around it if it has one: models leave the fence off, or
// open it and forget to close it. Or else any other fenced block, matched only to be skipped. A diagram
// that is still being written has no `</svg>` yet and stays ordinary text until it is complete.
const PIECE = /(?:```[ \t]*(?:svg|xml|html)?[ \t]*\r?\n\s*)?(<svg[\s>][\s\S]*?<\/svg>)(?:\s*```[ \t]*(?=\r?\n|$))?|```[^\n]*\n[\s\S]*?```/g

/**
 * Where to cut [text] to draw its complete SVG diagrams as pictures: alternating Markdown and SVG
 * source. Other code blocks are left alone, so SVG source shown as an example in them stays code.
 */
export function splitSvg(text: string): { text: string; svg: boolean }[] {
  const out: { text: string; svg: boolean }[] = []
  let last = 0
  for (const m of text.matchAll(PIECE)) {
    const svg = m[1]
    if (svg === undefined) continue
    if (m.index > last) out.push({ text: text.slice(last, m.index), svg: false })
    out.push({ text: svg, svg: true })
    last = m.index + m[0].length
  }
  if (last < text.length) out.push({ text: text.slice(last), svg: false })
  return out
}

const COMMENT = /<!--[\s\S]*?-->/y
const TAG = /<(\/?)([A-Za-z][\w:.-]*)((?:\s+[^\s=>/"']+(?:\s*=\s*(?:"[^"]*"|'[^']*'))?)*)\s*(\/?)>/y
const ATTR = /([^\s=>/"']+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'))?/g
const URL_REF = /url\(\s*['"]?([^)'"]*)['"]?\s*\)/gi

function attributeOk(rawName: string, value: string): boolean {
  const name = rawName.toLowerCase()
  if (name === 'xmlns' || name.startsWith('xmlns:')) return true
  const local = name.slice(name.lastIndexOf(':') + 1)
  if (local.startsWith('on')) return false
  if (local === 'href') return value.trim().startsWith('#')
  const low = value.trim().toLowerCase()
  if (low.includes('javascript:') || low.includes('data:') || low.includes('<script') || low.includes('@import')) return false
  for (const m of value.matchAll(URL_REF)) if (!m[1].trim().startsWith('#')) return false
  return true
}

/**
 * The SVG ready to be shown, or null when it is not a plain, reasonably small drawing: only the
 * whitelisted elements, no script / event handlers / external references / DOCTYPE. A missing
 * namespace on the root is added (models forget it, and without it a browser draws nothing).
 */
export function checkSvg(source: string): string | null {
  const s = source.trim()
  if (!s.startsWith('<svg') || !s.endsWith('</svg>') || s.length > MAX_CHARS) return null
  const stack: string[] = []
  let root = true
  let rootTag = ''
  let hasNs = false
  let at = 0
  while (at < s.length) {
    const lt = s.indexOf('<', at)
    if (lt < 0) break
    COMMENT.lastIndex = lt
    if (COMMENT.test(s)) {
      at = COMMENT.lastIndex
      continue
    }
    TAG.lastIndex = lt
    const m = TAG.exec(s)
    if (!m) return null // a DOCTYPE, CDATA, processing instruction, or just not well formed
    at = TAG.lastIndex
    const [whole, closing, name, attrs, selfClosing] = m
    if (!ELEMENTS.has(name)) return null
    if (closing) {
      if (stack.pop() !== name) return null
      continue
    }
    for (const a of attrs.matchAll(ATTR)) {
      const value = a[2] ?? a[3] ?? ''
      if (!attributeOk(a[1], value)) return null
      if (root && a[1] === 'xmlns') hasNs = value === SVG_NS
    }
    if (root) {
      if (name !== 'svg') return null
      root = false
      rootTag = whole
    }
    if (!selfClosing) {
      stack.push(name)
      if (stack.length > MAX_DEPTH) return null
    } else if (stack.length === 0) {
      return null // the root closed itself: nothing after it may follow
    }
  }
  if (stack.length !== 0) return null
  if (hasNs) return s
  if (/\sxmlns\s*=/.test(rootTag)) return null // a different namespace
  return s.replace('<svg', `<svg xmlns="${SVG_NS}"`)
}

/** The `src` for an <img> showing [svg]. */
export function svgDataUrl(svg: string): string {
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`
}
