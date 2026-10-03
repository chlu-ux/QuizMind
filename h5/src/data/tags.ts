/**
 * Knowledge-point tags come from the model, so near-duplicates are common: "UML"
 * and "UML 辨析", "Cache" and "cache", "数据流图" and "数据流图案例". This folds
 * them for statistics and for picking exam topics.
 */

/** Width- and whitespace-normalised form, for comparing tags. */
export function normalizeTag(tag: string): string {
  return tag.normalize('NFKC').replace(/\s+/g, ' ').trim()
}

const key = (tag: string) => normalizeTag(tag).toLowerCase()

/** The part before a path-like separator ("数据库/范式" → "数据库"). */
function base(tag: string): string {
  const n = normalizeTag(tag)
  const i = n.search(/\s*[/>›:|·]\s*/)
  return i > 0 ? n.slice(0, i).trim() : n
}

const isAsciiWord = (c: string) => /[A-Za-z0-9]/.test(c)

/**
 * Returns a function mapping a raw tag to the label it is shown under.
 *
 * Without [merge], tags that differ only in case, width or spacing share a label
 * (the most common spelling). With [merge], a tag also joins a shorter tag it
 * starts with ("UML 辨析" → "UML") and drops any "/"-style suffix. A one-letter
 * prefix never absorbs anything, and a Latin prefix only absorbs at a word
 * boundary, so "OSI" stays apart from "OS".
 */
export function tagLabeler(allTags: Iterable<string>, merge: boolean): (tag: string) => string {
  const seen = new Map<string, Map<string, number>>() // key → spelling → count
  for (const raw of allTags) {
    const k = key(merge ? base(raw) : raw)
    if (!k) continue
    const spelling = merge ? base(raw) : normalizeTag(raw)
    const m = seen.get(k) ?? new Map<string, number>()
    m.set(spelling, (m.get(spelling) ?? 0) + 1)
    seen.set(k, m)
  }
  const keys = [...seen.keys()].sort((a, b) => a.length - b.length || a.localeCompare(b))

  const root = new Map<string, string>()
  for (const k of keys) {
    let r = k
    if (merge) {
      for (const shorter of keys) {
        if (shorter.length >= k.length) break
        if (shorter.length < 2 || !k.startsWith(shorter)) continue
        const next = k[shorter.length]
        if (isAsciiWord(shorter[shorter.length - 1]) && isAsciiWord(next)) continue
        r = root.get(shorter) ?? shorter
        break
      }
    }
    root.set(k, r)
  }

  const label = (k: string) =>
    [...seen.get(k)!.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))[0][0]
  return (tag) => {
    const k = key(merge ? base(tag) : tag)
    return seen.has(k) ? label(root.get(k)!) : normalizeTag(tag)
  }
}
