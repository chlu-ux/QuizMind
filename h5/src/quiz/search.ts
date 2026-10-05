import type { LocalQuestion } from '@/data/types'
import { plainText } from './media'

/** Where a question matched, best first: a hit in the stem outranks one in an option or tag, which outranks the explanation. */
export type SearchWhere = 'stem' | 'option' | 'tag' | 'explanation'

export interface SearchHit {
  question: LocalQuestion
  /** The best place any term was found. */
  where: SearchWhere
  /** Text to show under the stem when the match is not in the stem (empty for a stem hit). */
  snippet: string
}

/** A run of text that either matched a search term or did not. */
export interface Piece {
  text: string
  hit: boolean
}

/** The text with every character width- and case-folded, remembering where each folded unit came from. */
interface Folded {
  text: string
  /** For each UTF-16 unit of `text`: the start and end offsets in the original it came from. */
  from: number[]
  to: number[]
}

/**
 * Folds [text] one character at a time (NFKC, then lower case), so a full-width "ＵＭＬ" and
 * a "uml" compare equal. Doing it per character, rather than on the whole string, keeps every
 * folded unit tied to a place in the original, which is what highlighting needs.
 */
function fold(text: string): Folded {
  let out = ''
  const from: number[] = []
  const to: number[] = []
  let at = 0
  for (const ch of text) {
    const end = at + ch.length
    const f = ch.normalize('NFKC').toLowerCase()
    for (let i = 0; i < f.length; i++) {
      from.push(at)
      to.push(end)
    }
    out += f
    at = end
  }
  return { text: out, from, to }
}

/** Search words: the query folded and split on whitespace, duplicates dropped. Empty for a blank query. */
export function searchTerms(query: string): string[] {
  const terms = fold(query).text.split(/\s+/).filter(Boolean)
  return [...new Set(terms)]
}

const RANK: Record<SearchWhere, number> = { stem: 0, option: 1, tag: 1, explanation: 2 }
const ORDER: SearchWhere[] = ['stem', 'option', 'tag', 'explanation']

/** Characters of context kept either side of a hit in a long explanation. */
const BEFORE = 24
const AFTER = 48

function fieldsOf(q: LocalQuestion): Record<SearchWhere, string[]> {
  return {
    stem: [plainText(q.stem)],
    option: q.options.map(plainText),
    tag: q.tags,
    explanation: q.explanation ? [plainText(q.explanation)] : [],
  }
}

/** Where in [text] the first of [terms] occurs, as offsets in the original; null if none does. */
function firstHit(text: string, terms: string[]): { start: number; end: number } | null {
  const f = fold(text)
  let best: { start: number; end: number } | null = null
  for (const t of terms) {
    const i = f.text.indexOf(t)
    if (i < 0) continue
    if (!best || f.from[i] < best.start) best = { start: f.from[i], end: f.to[i + t.length - 1] }
  }
  return best
}

function snippetOf(where: SearchWhere, texts: string[], terms: string[]): string {
  if (where === 'stem') return ''
  for (const t of texts) {
    const hit = firstHit(t, terms)
    if (!hit) continue
    if (where !== 'explanation') return t
    const from = Math.max(0, hit.start - BEFORE)
    const to = Math.min(t.length, hit.end + AFTER)
    return (from > 0 ? '…' : '') + t.slice(from, to).replace(/\s+/g, ' ') + (to < t.length ? '…' : '')
  }
  return ''
}

/**
 * The questions that contain every word of [query] (case, width and spacing ignored) somewhere in
 * the stem, options, tags or explanation. Words are matched as plain text, never as patterns.
 * Stem hits come first, then option / tag hits, then explanation-only hits; ties keep the order
 * of [questions]. Withdrawn questions and blank queries give nothing.
 */
export function searchQuestions(questions: LocalQuestion[], query: string): SearchHit[] {
  const terms = searchTerms(query)
  if (terms.length === 0) return []
  const hits: SearchHit[] = []
  for (const q of questions) {
    if (q.hidden) continue
    const fields = fieldsOf(q)
    const folded = ORDER.flatMap((w) => fields[w].map((t) => ({ w, text: fold(t).text })))
    const all = folded.map((f) => f.text).join('\n')
    if (!terms.every((t) => all.includes(t))) continue
    const where = ORDER.find((w) => folded.some((f) => f.w === w && terms.some((t) => f.text.includes(t))))!
    hits.push({ question: q, where, snippet: snippetOf(where, fields[where], terms) })
  }
  return hits
    .map((h, i) => ({ h, i }))
    .sort((a, b) => RANK[a.h.where] - RANK[b.h.where] || a.i - b.i)
    .map((x) => x.h)
}

/**
 * Cuts [text] into runs, marking those that match one of [terms]. Overlapping and touching
 * matches are merged, so the pieces are in order, never empty, and join back into [text].
 */
export function highlight(text: string, terms: string[]): Piece[] {
  const f = fold(text)
  const spans: [number, number][] = []
  for (const raw of terms) {
    const t = fold(raw).text
    if (!t) continue
    for (let i = f.text.indexOf(t); i >= 0; i = f.text.indexOf(t, i + 1)) spans.push([f.from[i], f.to[i + t.length - 1]])
  }
  spans.sort((a, b) => a[0] - b[0] || a[1] - b[1])
  const merged: [number, number][] = []
  for (const s of spans) {
    const last = merged[merged.length - 1]
    if (last && s[0] <= last[1]) last[1] = Math.max(last[1], s[1])
    else merged.push([s[0], s[1]])
  }
  const out: Piece[] = []
  let at = 0
  for (const [a, b] of merged) {
    if (a > at) out.push({ text: text.slice(at, a), hit: false })
    out.push({ text: text.slice(a, b), hit: true })
    at = b
  }
  if (at < text.length) out.push({ text: text.slice(at), hit: false })
  return out
}
