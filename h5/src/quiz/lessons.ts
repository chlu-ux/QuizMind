import type { Lesson, LocalAttempt, LocalQuestion } from '@/data/types'

/** A chapter of the study text: one imported document, with its sections in reading order. */
export interface Chapter {
  id: string
  title: string
  lessons: Lesson[]
}

/** The section's own title: the last part of its heading path ("考点精讲 > 2.1 操作系统概述" gives "2.1 操作系统概述"). */
export function lessonTitle(l: Lesson): string {
  const parts = l.heading_path.split(' > ')
  return parts[parts.length - 1].trim() || l.heading_path
}

/**
 * Chapter names for a bank's documents. Documents of one bank usually share a long prefix
 * ("软件设计师（中级）考点精讲（操作系统）"), so what they have in common is dropped and the part in
 * brackets is kept; a title that is nothing but the prefix stays whole.
 */
export function shortTitles(titles: string[]): string[] {
  if (titles.length < 2) return titles
  let prefix = titles[0]
  for (const t of titles) {
    let i = 0
    while (i < prefix.length && i < t.length && prefix[i] === t[i]) i++
    prefix = prefix.slice(0, i)
  }
  prefix = prefix.replace(/[（(]$/, '') // an opening bracket belongs to what follows
  if (prefix.length < 2) return titles
  return titles.map((t) => {
    let rest = t.slice(prefix.length).trim()
    if (/^[（(]/.test(rest) && /[）)]$/.test(rest)) rest = rest.slice(1, -1).trim()
    return rest || t
  })
}

/** The sections grouped into chapters, chapters in the order the documents were added. */
export function groupChapters(lessons: Lesson[]): Chapter[] {
  const byDoc = new Map<string, Lesson[]>()
  for (const l of lessons) {
    const list = byDoc.get(l.document_id)
    if (list) list.push(l)
    else byDoc.set(l.document_id, [l])
  }
  const docs = [...byDoc.values()]
    .map((list) => list.sort((a, b) => a.seq - b.seq))
    .sort((a, b) => a[0].document_created_at - b[0].document_created_at || a[0].document_id.localeCompare(b[0].document_id))
  const names = shortTitles(docs.map((list) => list[0].document_title))
  return docs.map((list, i) => ({ id: list[0].document_id, title: names[i], lessons: list }))
}

/** How far along a section is. Each state includes the ones before it. */
export type LessonState = 'new' | 'read' | 'practiced' | 'mastered'

export interface LessonProgress {
  state: LessonState
  /** Marked as read by the learner, whatever else was done with the section. */
  read: boolean
  /** Questions generated from the section. */
  total: number
  /** Of those, how many were answered at least once. */
  answered: number
  /** Of the answered ones, how many were right the last time. */
  correct: number
  /** Share of the answered questions that were right the last time, 0-100; null if none was answered. */
  accuracy: number | null
}

/** A section counts as mastered once this many of its questions (all of them, if it has fewer) were answered... */
export const MASTER_MIN_ANSWERED = 5
/** ...and at least this share (percent) of those were right the last time. */
export const MASTER_MIN_ACCURACY = 80

/**
 * Progress of every section of [lessons]. Practice is judged by the latest attempt at each
 * question, like the "最近一次答对" figure on the bank page, so a question learned since stops counting against you.
 */
export function lessonProgress(
  lessons: Lesson[],
  questions: LocalQuestion[],
  attempts: LocalAttempt[],
  readIds: Set<string>,
): Map<string, LessonProgress> {
  const last = new Map<string, boolean>()
  for (const a of [...attempts].sort((x, y) => x.answered_at - y.answered_at)) last.set(a.question_id, a.is_correct)
  const byLesson = new Map<string, LocalQuestion[]>()
  for (const q of questions) {
    if (!q.chunk_id) continue
    const list = byLesson.get(q.chunk_id)
    if (list) list.push(q)
    else byLesson.set(q.chunk_id, [q])
  }
  const out = new Map<string, LessonProgress>()
  for (const l of lessons) {
    const qs = byLesson.get(l.id) ?? []
    let answered = 0
    let correct = 0
    for (const q of qs) {
      const r = last.get(q.id)
      if (r === undefined) continue
      answered++
      if (r) correct++
    }
    const accuracy = answered ? Math.round((correct * 100) / answered) : null
    const read = readIds.has(l.id)
    let state: LessonState = read ? 'read' : 'new'
    if (answered > 0) state = 'practiced'
    if (qs.length > 0 && answered >= Math.min(qs.length, MASTER_MIN_ANSWERED) && correct * 100 >= MASTER_MIN_ACCURACY * answered) {
      state = 'mastered'
    }
    out.set(l.id, { state, read, total: qs.length, answered, correct, accuracy })
  }
  return out
}

export const STATE_LABEL: Record<LessonState, string> = {
  new: '未学',
  read: '已读',
  practiced: '练习中',
  mastered: '已掌握',
}

/** The questions generated from a section, in the bank's order. */
export function lessonQuestions(lessonId: string, questions: LocalQuestion[]): LocalQuestion[] {
  return questions.filter((q) => q.chunk_id === lessonId)
}

/**
 * Where "继续学习" goes: the first section not read yet (practising it does not count as reading it),
 * else the first one with questions not mastered yet; null when everything is read and mastered. [lessons] must be in reading order.
 */
export function nextToStudy(lessons: Lesson[], progress: Map<string, LessonProgress>): Lesson | null {
  return (
    lessons.find((l) => !progress.get(l.id)?.read) ??
    lessons.find((l) => {
      const p = progress.get(l.id)
      return !!p && p.total > 0 && p.state !== 'mastered' // a section without questions has nothing left to master
    }) ??
    null
  )
}

/** Sentences of a Chinese paragraph, each keeping its closing 。！？ and any closing quote or bracket. */
export function splitSentences(paragraph: string): string[] {
  const lines = paragraph.split('\n').map((s) => s.trim()).filter(Boolean)
  let text = ''
  for (const line of lines) {
    // Lines of a hard-wrapped paragraph join with a space only between two Latin words.
    text += text && /[A-Za-z0-9]$/.test(text) && /^[A-Za-z0-9]/.test(line) ? ' ' + line : line
  }
  const parts = text.match(/[^。！？]+[。！？]+[」』”’）)]*|[^。！？]+$/g) ?? []
  return parts.map((s) => s.trim()).filter(Boolean)
}

/** A piece of a section's text: a paragraph of plain prose cut into sentences, or anything else to render as it is. */
export type LessonBlock = { kind: 'prose'; sentences: string[] } | { kind: 'md'; source: string }

const STRUCTURED = /!\[|^\s*([-*+]|\d+[.)])\s|^\s*#|^\s*>|^\s*\||^\s*(```|~~~)/m

/**
 * Cuts a section into blocks. The study text is written as dense paragraphs; showing one sentence
 * per line makes them readable, and lets the reader cover sentences to test their memory. Lists,
 * tables, code and pictures are left alone.
 */
export function lessonBlocks(text: string): LessonBlock[] {
  const blocks: string[] = []
  let cur: string[] = []
  let fence = ''
  const flush = () => {
    if (cur.length) blocks.push(cur.join('\n'))
    cur = []
  }
  for (const line of text.replace(/\r\n?/g, '\n').split('\n')) {
    const m = /^\s{0,3}(`{3,}|~{3,})/.exec(line)
    if (m) fence = fence === '' ? m[1][0] : line.trim().startsWith(fence) ? '' : fence
    if (!fence && !m && line.trim() === '') flush()
    else cur.push(line)
  }
  flush()
  return blocks.map((b): LessonBlock => {
    if (STRUCTURED.test(b)) return { kind: 'md', source: b }
    const sentences = splitSentences(b)
    return sentences.length > 1 ? { kind: 'prose', sentences } : { kind: 'md', source: b }
  })
}
