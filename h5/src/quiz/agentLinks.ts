/** The two kinds of link the assistant writes (docs/agent-design.md §5.3). */
export type AgentLink = { kind: 'lesson' | 'question'; id: string }

/** Splits `lesson:ID` / `question:ID`. Anything else (an ordinary web link, a made-up scheme) is not ours. */
export function parseAgentLink(href: string | null | undefined): AgentLink | null {
  if (!href) return null
  for (const kind of ['lesson', 'question'] as const) {
    const prefix = `${kind}:`
    if (href.startsWith(prefix)) {
      const id = href.slice(prefix.length).trim()
      return id ? { kind, id } : null
    }
  }
  return null
}

/** Where a conversation starts: what the learner is looking at. */
export interface AgentArgs {
  bankId: string
  lessonId: string
  questionId: string
  /** The option indexes the learner picked for [questionId]. */
  selected: number[]
}

export function agentArgs(a: Partial<AgentArgs> = {}): AgentArgs {
  return { bankId: '', lessonId: '', questionId: '', selected: [], ...a }
}

/** The route query for [args] (and [text], put into the box but not sent). */
export function agentQuery(args: AgentArgs, text = ''): Record<string, string> {
  const q: Record<string, string> = {}
  if (args.bankId) q.bank = args.bankId
  if (args.lessonId) q.lesson = args.lessonId
  if (args.questionId) {
    q.question = args.questionId
    q.selected = args.selected.join(',')
  }
  if (text) q.text = text
  return q
}

type Query = Record<string, unknown>

/** The inverse of [agentQuery]; a hand-edited address cannot produce anything but a valid conversation start. */
export function argsFromQuery(query: Query): { args: AgentArgs; text: string } {
  const one = (k: string) => {
    const v = query[k]
    return typeof v === 'string' ? v : Array.isArray(v) && typeof v[0] === 'string' ? v[0] : ''
  }
  const selected = one('selected')
    .split(',')
    .filter((s) => /^\d+$/.test(s))
    .map(Number)
  return {
    args: agentArgs({
      bankId: one('bank'),
      lessonId: one('lesson'),
      questionId: one('question'),
      selected,
    }),
    text: one('text'),
  }
}
