/**
 * Pictures inside question text. A stem, option or explanation refers to an uploaded picture as
 * `![alt](media:<id>)`; the server hands the bytes out at `/api/v1/media/<id>`.
 */
const IMAGE = /!\[([^\]]*)\]\(media:([0-9a-f]{24})\)/g

export function mediaUrl(id: string): string {
  return `/api/v1/media/${id}`
}

/** Markdown with every `media:<id>` address replaced by the URL it can be fetched from. */
export function withMediaUrls(markdown: string): string {
  return markdown.replace(IMAGE, (_, alt: string, id: string) => `![${alt}](${mediaUrl(id)})`)
}

/** Question text with each picture replaced by a short placeholder, for one-line summaries. */
export function plainText(text: string): string {
  return text.replace(IMAGE, (_, alt: string) => (alt.trim() ? `[图：${alt.trim()}]` : '[图]'))
}

export type Segment = { kind: 'text'; text: string } | { kind: 'image'; src: string; alt: string }

/**
 * Splits an option into text and pictures. Options are plain text (they may hold `*p++` or `<T>`,
 * which Markdown would mangle), so only the picture syntax is interpreted.
 */
export function segments(text: string): Segment[] {
  const out: Segment[] = []
  let last = 0
  for (const m of text.matchAll(IMAGE)) {
    if (m.index > last) out.push({ kind: 'text', text: text.slice(last, m.index) })
    out.push({ kind: 'image', src: mediaUrl(m[2]), alt: m[1] })
    last = m.index + m[0].length
  }
  if (last < text.length) out.push({ kind: 'text', text: text.slice(last) })
  return out
}

/** A diagram the AI drew as SVG that is safe and small enough to show. */
export function isPlainSvg(svg: string): boolean {
  const s = svg.trim()
  return s.startsWith('<svg') && s.endsWith('</svg>') && s.length <= 60_000 && !/<(script|foreignObject|image)\b/i.test(s)
}

/** The SVG as an address for an <img>: an image never runs scripts, whatever the SVG contains. */
export function svgDataUri(svg: string): string {
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg.trim())}`
}

// An `<svg>` element, with the fence around it if it has one (models leave the fence off, or open it
// and forget to close it), or else any other fenced block, which is matched only to be skipped.
const SVG_OR_FENCE =
  /(?:```[ \t]*(?:svg|xml|html)?[ \t]*\r?\n\s*)?(<svg[\s>][\s\S]*?<\/svg>)(?:\s*```[ \t]*(?=\r?\n|$))?|```[^\n]*\n[\s\S]*?```/g

/**
 * Markdown in which every finished SVG diagram sits in a properly closed ```svg block. The model is
 * asked to fence its drawing, but sometimes leaves the `<svg>` bare, fences it as xml/html or never
 * closes the fence; all of them are diagrams. Other code blocks are left alone, so SVG source shown as
 * an example in them stays code.
 */
export function fenceSvg(markdown: string): string {
  return markdown.replace(SVG_OR_FENCE, (m, svg: string | undefined) => (svg ? `\n\n\`\`\`svg\n${svg}\n\`\`\`\n\n` : m))
}
