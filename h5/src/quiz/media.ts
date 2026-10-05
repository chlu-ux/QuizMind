/**
 * Pictures inside question text. A stem, option or explanation refers to an uploaded picture as
 * `![alt](media:<id>)`; the server hands the bytes out at `/api/v1/media/<id>`.
 */
const IMAGE = /!\[([^\]]*)\]\(media:([0-9a-f]{24})\)/g

/** Where a `media:<id>` reference can be fetched from. Anything else is returned unchanged. */
export function mediaUrl(src: string, base = ''): string {
  const m = /^media:([0-9a-f]{24})$/.exec(src)
  return m ? `${base}/api/v1/media/${m[1]}` : src
}

/** Question text with each picture replaced by a short placeholder, for lists and search. */
export function plainText(text: string): string {
  return text.replace(IMAGE, (_, alt: string) => (alt.trim() ? `[图：${alt.trim()}]` : '[图]'))
}

export type Segment = { kind: 'text'; text: string } | { kind: 'image'; src: string; alt: string }

/**
 * Splits an option into text and pictures. Options are shown as plain text (they may hold `*p++`
 * or `<T>`, which Markdown would mangle), so only the picture syntax is interpreted.
 */
export function segments(text: string): Segment[] {
  const out: Segment[] = []
  let last = 0
  for (const m of text.matchAll(IMAGE)) {
    if (m.index > last) out.push({ kind: 'text', text: text.slice(last, m.index) })
    out.push({ kind: 'image', src: mediaUrl(`media:${m[2]}`), alt: m[1] })
    last = m.index + m[0].length
  }
  if (last < text.length) out.push({ kind: 'text', text: text.slice(last) })
  return out
}
