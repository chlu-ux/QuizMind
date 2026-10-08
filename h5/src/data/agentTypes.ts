// What the study assistant's server API sends and receives (docs/agent-design.md §6.7).

/** Thrown when the assistant cannot be reached or refuses; message is safe to show. */
export class AgentError extends Error {
  constructor(
    message: string,
    readonly status?: number,
    readonly code?: string,
  ) {
    super(message)
  }
}

/** Whether the assistant can be used, from GET /agent/status. */
export interface AgentStatus {
  available: boolean
  model: string
  /** A second model double-checks the questions the assistant writes. */
  verified: boolean
  /** The model can look at pictures, so pictures may be attached to a message. */
  vision: boolean
}

/** A question the assistant wrote that waits for the learner to accept or discard it. */
export interface AgentDraft {
  id: string
  lessonId: string
  type: 'single' | 'judge'
  stem: string
  options: string[]
  answerIndex: number
  explanation: string
  difficulty: number
  tags: string[]
  sourceQuote: string
  /** A second model answered it independently and agreed. */
  verified: boolean
  /**
   * Already adopted when the server sent it: part of the question bank (or the review queue). False from
   * a server that predates adoption, and for an old-style draft nobody decided on.
   */
  adopted: boolean
}

export function draftFromJson(j: Record<string, unknown>): AgentDraft {
  const str = (v: unknown) => (typeof v === 'string' ? v : '')
  const num = (v: unknown, d: number) => (typeof v === 'number' ? v : d)
  const list = (v: unknown) => (Array.isArray(v) ? v.map((x) => String(x)) : [])
  return {
    id: str(j.draft_id),
    lessonId: str(j.lesson_id),
    type: j.type === 'judge' ? 'judge' : 'single',
    stem: str(j.stem),
    options: list(j.options),
    answerIndex: num(j.answer_index, 0),
    explanation: str(j.explanation),
    difficulty: num(j.difficulty, 3),
    tags: list(j.tags),
    sourceQuote: str(j.source_quote),
    verified: j.verified === true,
    adopted: j.adopted === true,
  }
}

/** What the learner is looking at, which the server puts into the assistant's instructions. */
export interface AgentContext {
  bankId?: string
  lessonId?: string
  questionId?: string
  /** The option indexes the learner picked for [questionId]. */
  selected?: number[]
}

export interface AgentChatRequest {
  /** Chosen by the app; the server keeps the conversation under it and reads the history itself. */
  conversationId: string
  /** Left out: the whole assistant. `learn` asks for the older read-only form. */
  mode?: AgentMode
  deviceId: string
  /** The new question; the earlier ones are on the server. */
  message: { text: string; attachmentIds?: string[] }
  context: AgentContext
}

export type AgentMode = 'learn' | 'create'

export function chatRequestJson(r: AgentChatRequest) {
  const c = r.context
  return {
    conversation_id: r.conversationId,
    ...(r.mode ? { mode: r.mode } : {}),
    device_id: r.deviceId,
    message: { text: r.message.text, attachment_ids: r.message.attachmentIds ?? [] },
    context: {
      ...(c.bankId ? { bank_id: c.bankId } : {}),
      ...(c.lessonId ? { lesson_id: c.lessonId } : {}),
      ...(c.questionId ? { question: { id: c.questionId, selected: c.selected ?? [] } } : {}),
    },
  }
}

/** Events of POST /agent/chat, in the order they arrive. */
export type AgentEvent =
  | { kind: 'start'; conversationId: string }
  | { kind: 'delta'; text: string }
  | { kind: 'tool'; id: string; name: string; label: string; status: 'running' | 'done' | 'error' }
  | { kind: 'drafts'; drafts: AgentDraft[] }
  | { kind: 'done'; stop: string; inputTokens: number; outputTokens: number }
  | { kind: 'error'; code: string; message: string }

function eventOf(name: string, j: Record<string, unknown>): AgentEvent | null {
  const n = (v: unknown) => (typeof v === 'number' ? v : 0)
  switch (name) {
    case 'start':
      return { kind: 'start', conversationId: typeof j.conversation_id === 'string' ? j.conversation_id : '' }
    case 'delta':
      return typeof j.text === 'string' && j.text ? { kind: 'delta', text: j.text } : null
    case 'tool': {
      const s = j.status
      return {
        kind: 'tool',
        id: typeof j.id === 'string' ? j.id : '',
        name: typeof j.name === 'string' ? j.name : '',
        label: typeof j.label === 'string' ? j.label : '',
        status: s === 'done' || s === 'error' ? s : 'running',
      }
    }
    case 'drafts':
      if (!Array.isArray(j.drafts)) return null
      return {
        kind: 'drafts',
        drafts: j.drafts.filter((d): d is Record<string, unknown> => !!d && typeof d === 'object').map(draftFromJson),
      }
    case 'done': {
      const u = (j.usage && typeof j.usage === 'object' ? j.usage : {}) as Record<string, unknown>
      return {
        kind: 'done',
        stop: typeof j.stop === 'string' ? j.stop : 'end_turn',
        inputTokens: n(u.input),
        outputTokens: n(u.output),
      }
    }
    case 'error':
      return {
        kind: 'error',
        code: typeof j.code === 'string' ? j.code : 'internal',
        message: typeof j.message === 'string' ? j.message : '助手出错了',
      }
  }
  return null
}

/**
 * Events of a server-sent-events body. Unlike a chat completion's stream these are named (`event:`
 * then `data:`), and comment lines (`: ping`) only keep the connection alive. Events this app does
 * not know are skipped, so a newer server can add some.
 *
 * Read with getReader(): async iteration of a ReadableStream is missing in Safari.
 */
export async function* parseAgentSse(body: ReadableStream<Uint8Array>): AsyncGenerator<AgentEvent> {
  const reader = body.getReader()
  const decoder = new TextDecoder()
  let name: string | null = null
  let data: string[] = []

  const flush = (): AgentEvent | null => {
    const n = name
    const lines = data
    name = null
    data = []
    if (n === null || lines.length === 0) return null
    try {
      const j: unknown = JSON.parse(lines.join('\n'))
      return j && typeof j === 'object' && !Array.isArray(j) ? eventOf(n, j as Record<string, unknown>) : null
    } catch {
      return null
    }
  }
  const feed = (line: string): AgentEvent | null => {
    if (line === '') return flush()
    if (line.startsWith(':')) return null
    if (line.startsWith('event:')) name = line.slice(6).trim()
    else if (line.startsWith('data:')) data.push(line.slice(5).replace(/^\s+/, ''))
    return null
  }

  let pending = ''
  try {
    for (;;) {
      const { value, done } = await reader.read()
      if (done) break
      pending += decoder.decode(value, { stream: true })
      const lines = pending.split(/\r?\n/)
      pending = lines.pop() ?? ''
      for (const line of lines) {
        const e = feed(line)
        if (e) yield e
      }
    }
    pending += decoder.decode()
    if (pending) {
      const e = feed(pending)
      if (e) yield e
    }
    const last = flush()
    if (last) yield last
  } finally {
    // Stops the download when the consumer gives up early.
    reader.cancel().catch(() => {})
  }
}

/** What became of a draft: still waiting, sent to review, or thrown away. */
export type DraftPhase = 'pending' | 'accepted' | 'discarded'

export interface StoredDraft {
  draft: AgentDraft
  phase: DraftPhase
}

/** A conversation as the history list shows it. */
export interface AgentConversationItem {
  id: string
  mode: AgentMode
  title: string
  bankId: string
  lessonId: string
  questionId: string
  messageCount: number
  /** Drafts nobody has decided on yet. */
  pendingDrafts: number
  updatedAt: number
}

export interface AgentConversationPage {
  items: AgentConversationItem[]
  hasMore: boolean
}

/** A file a message carried. */
export interface AgentAttachment {
  id: string
  kind: 'text' | 'image'
  name: string
  mime: string
  /** Bytes as uploaded. */
  size: number
  /** Text files: characters of the text. */
  chars: number
  /** Pictures: pixels, 0 when the server could not read them. */
  width: number
  height: number
}

/** What the server accepts. The server checks them again; these only spare a round trip. */
export const ATTACH_EXTENSIONS = ['.md', '.markdown', '.txt', '.csv', '.json', '.log']
export const ATTACH_MAX_BYTES = 512 * 1024
/** Files in a conversation, and in one message. */
export const ATTACH_MAX_FILES = 8
export const ATTACH_MAX_PER_MESSAGE = 4
/** Pictures: the types taken (the server judges by content), the size, and how many a conversation holds. */
export const ATTACH_IMAGE_TYPES = ['image/jpeg', 'image/png', 'image/gif', 'image/webp']
export const ATTACH_IMAGE_EXTENSIONS = ['.jpg', '.jpeg', '.png', '.gif', '.webp']
export const ATTACH_IMAGE_MAX_BYTES = 5 * 1024 * 1024
export const ATTACH_MAX_IMAGES = 4

export function attachmentFromJson(j: Record<string, unknown>): AgentAttachment {
  return {
    id: text(j.id),
    kind: j.kind === 'image' ? 'image' : 'text',
    name: text(j.name),
    mime: text(j.mime),
    size: whole(j.size),
    chars: whole(j.chars),
    width: whole(j.width),
    height: whole(j.height),
  }
}

export interface StoredMessage {
  id: number
  role: 'user' | 'assistant'
  text: string
  tools: { id: string; label: string; status: 'running' | 'done' | 'error' }[]
  drafts: StoredDraft[]
  attachments: AgentAttachment[]
  note: string
  error: string
  createdAt: number
}

/** A whole conversation, to show it again and carry on. */
export interface AgentConversationDetail {
  id: string
  mode: AgentMode
  title: string
  bankId: string
  lessonId: string
  questionId: string
  messages: StoredMessage[]
}

const text = (v: unknown) => (typeof v === 'string' ? v : '')
const whole = (v: unknown) => (typeof v === 'number' ? v : 0)

export function conversationItemFromJson(j: Record<string, unknown>): AgentConversationItem {
  return {
    id: text(j.id),
    mode: j.mode === 'create' ? 'create' : 'learn',
    title: text(j.title),
    bankId: text(j.bank_id),
    lessonId: text(j.lesson_id),
    questionId: text(j.question_id),
    messageCount: whole(j.message_count),
    pendingDrafts: whole(j.pending_drafts),
    updatedAt: whole(j.updated_at),
  }
}

export function conversationFromJson(j: Record<string, unknown>): AgentConversationDetail {
  const list = (v: unknown): Record<string, unknown>[] =>
    Array.isArray(v) ? v.filter((x): x is Record<string, unknown> => !!x && typeof x === 'object') : []
  return {
    ...conversationItemFromJson(j),
    messages: list(j.messages).map((m) => ({
      id: whole(m.id),
      role: m.role === 'assistant' ? 'assistant' : 'user',
      text: text(m.text),
      tools: list(m.tools).map((t) => ({
        id: text(t.id),
        label: text(t.label),
        status: t.status === 'error' ? 'error' : t.status === 'running' ? 'running' : 'done',
      })),
      drafts: list(m.drafts).map((d) => ({
        draft: draftFromJson(d),
        phase: d.phase === 'accepted' ? 'accepted' : d.phase === 'discarded' ? 'discarded' : 'pending',
      })),
      attachments: list(m.attachments).map(attachmentFromJson),
      note: text(m.note),
      error: text(m.error),
      createdAt: whole(m.created_at),
    })),
  }
}
