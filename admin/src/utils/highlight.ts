/**
 * Locate a source quote inside the raw Markdown of a chunk.
 *
 * The server verifies quotes after normalising both sides (NFKC, lower case,
 * letters and digits only), so the quote usually differs from the raw text in
 * punctuation and Markdown markup. This applies the same normalisation while
 * remembering where each kept character came from, so the match can be mapped
 * back to a range in the raw text.
 */
export interface Range {
  start: number
  end: number // exclusive
}

const isKept = (ch: string) => /[\p{L}\p{N}]/u.test(ch)

function normalizeWithMap(text: string): { norm: string; map: number[] } {
  let norm = ''
  const map: number[] = []
  let i = 0
  for (const ch of text) {
    // NFKC can expand one character into several (e.g. full-width forms, ligatures).
    for (const c of ch.normalize('NFKC').toLowerCase()) {
      if (isKept(c)) {
        norm += c
        map.push(i)
      }
    }
    i += ch.length
  }
  return { norm, map }
}

export function findQuote(text: string, quote: string): Range | null {
  const q = normalizeWithMap(quote).norm
  if (!q) return null
  const { norm, map } = normalizeWithMap(text)
  const at = norm.indexOf(q)
  if (at < 0) return null
  // `norm` and `map` are indexed per UTF-16 unit of the normalised string; map has one entry per
  // *character*, so convert the unit offset into a character offset first.
  const charAt = [...norm.slice(0, at)].length
  const charLen = [...q].length
  const start = map[charAt]
  const lastStart = map[charAt + charLen - 1]
  // Include the whole last character (it may be a surrogate pair).
  const lastCodePoint = String.fromCodePoint(text.codePointAt(lastStart)!)
  return { start, end: lastStart + lastCodePoint.length }
}

export interface Segment {
  text: string
  mark: boolean
}

export function splitByRange(text: string, r: Range | null): Segment[] {
  if (!r) return [{ text, mark: false }]
  return [
    { text: text.slice(0, r.start), mark: false },
    { text: text.slice(r.start, r.end), mark: true },
    { text: text.slice(r.end), mark: false },
  ].filter((s) => s.text !== '')
}
