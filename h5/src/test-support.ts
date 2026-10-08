import { openDb, type Db } from '@/data/db'
import { ApiError, type QuizApi } from '@/data/api'
import type { AgentApi } from '@/data/agentApi'
import {
  AgentError,
  draftFromJson,
  type AgentAttachment,
  type AgentChatRequest,
  type AgentConversationDetail,
  type AgentConversationPage,
  type AgentDraft,
  type AgentEvent,
  type AgentStatus,
  type StoredMessage,
} from '@/data/agentTypes'
import type {
  AttemptDto,
  AttemptsPage,
  Bank,
  ExamRecord,
  ExamsPage,
  FlagReason,
  Lesson,
  LessonsPage,
  Question,
  SessionDto,
  SessionsPage,
  StateDto,
} from '@/data/types'

export function question(id: string, o: Partial<Question> = {}): Question {
  return {
    id,
    bank_id: 'b1',
    type: 'single',
    stem: `题干 ${id}`,
    options: ['A', 'B', 'C', 'D'],
    answer: [1],
    explanation: '解析',
    difficulty: 2,
    tags: ['t'],
    source_quote: '原文',
    sync_seq: 1,
    ...o,
  }
}

/** An in-memory stand-in for the server that records uploads. */
export class FakeApi implements QuizApi {
  bankList: Bank[] = [{ id: 'b1', title: '题库', description: '', question_count: 0 }]
  published: Question[] = []
  withdrawn: string[] = []
  remoteStates: StateDto[] = []
  uploadedAttempts: AttemptDto[] = []
  uploadedStates: StateDto[] = []
  /** What other devices uploaded; the pull side of attempt and exam sync. */
  remoteAttempts: AttemptDto[] = []
  remoteExams: ExamRecord[] = []
  uploadedExams: ExamRecord[] = []
  /** Behave like a server from before attempt/exam download existed (404). */
  historyUnsupported = false
  flagged: string[] = []
  flagReasons: (string | undefined)[] = []
  pageSize = 1000
  failWith: Error | null = null
  flagError: Error | null = null

  /** Saved quizzes by scope, with the server sequence of their last change. */
  sessions = new Map<string, { dto: SessionDto; seq: number }>()
  private sessionSeq = 0
  /** Behave like a server from before progress sync existed (404). */
  sessionsUnsupported = false

  /** The study text, as the server would hand it out; bump [lessonsVersion] after changing it. */
  lessonList: Lesson[] = []
  lessonsVersion = 1
  lessonsUnsupported = false
  lessonFetches = 0

  private check() {
    if (this.failWith) throw this.failWith
  }
  async banks() {
    this.check()
    return this.bankList
  }
  async syncQuestions(since: number) {
    this.check()
    const rows = this.published.filter((q) => q.sync_seq > since).sort((a, b) => a.sync_seq - b.sync_seq)
    const take = rows.slice(0, this.pageSize)
    return {
      items: take,
      deleted: take.length ? this.withdrawn : [],
      next_seq: take.length ? take[take.length - 1].sync_seq : since,
      has_more: rows.length > take.length,
    }
  }
  async syncStates(since: number) {
    this.check()
    return { items: this.remoteStates, next_seq: this.remoteStates.length ? 99 : since, has_more: false }
  }
  async uploadAttempts(a: AttemptDto[]) {
    this.check()
    this.uploadedAttempts.push(...a)
  }
  async syncAttempts(since: number, limit = 500): Promise<AttemptsPage> {
    this.check()
    if (this.historyUnsupported) throw new ApiError('not found', 404)
    // The fake's sequence number is the 1-based position in the list.
    const rows = this.remoteAttempts.map((a, i) => ({ a, seq: i + 1 })).filter((r) => r.seq > since)
    const take = rows.slice(0, limit)
    return {
      items: take.map((r) => r.a),
      next_seq: take.length ? take[take.length - 1].seq : since,
      has_more: rows.length > take.length,
    }
  }
  async syncExams(since: number, limit = 100): Promise<ExamsPage> {
    this.check()
    if (this.historyUnsupported) throw new ApiError('not found', 404)
    const rows = this.remoteExams.map((e, i) => ({ e, seq: i + 1 })).filter((r) => r.seq > since)
    const take = rows.slice(0, limit)
    return {
      items: take.map((r) => r.e),
      next_seq: take.length ? take[take.length - 1].seq : since,
      has_more: rows.length > take.length,
    }
  }
  async uploadExams(e: ExamRecord[]) {
    this.check()
    if (this.historyUnsupported) throw new ApiError('not found', 404)
    this.uploadedExams.push(...e)
  }
  async uploadStates(s: StateDto[]) {
    this.check()
    this.uploadedStates.push(...s)
  }
  async syncSessions(since: number, limit = 100): Promise<SessionsPage> {
    this.check()
    if (this.sessionsUnsupported) throw new ApiError('not found', 404)
    const rows = [...this.sessions.values()].filter((r) => r.seq > since).sort((a, b) => a.seq - b.seq)
    const take = rows.slice(0, limit)
    return {
      items: take.map((r) => r.dto),
      next_seq: take.length ? take[take.length - 1].seq : since,
      has_more: rows.length > take.length,
    }
  }
  async uploadSessions(list: SessionDto[]) {
    this.check()
    if (this.sessionsUnsupported) throw new ApiError('not found', 404)
    for (const dto of list) {
      const have = this.sessions.get(dto.scope)
      if (have && have.dto.updated_at >= dto.updated_at) continue // last writer wins
      this.sessions.set(dto.scope, { dto, seq: ++this.sessionSeq })
    }
  }
  async lessons(version: number): Promise<LessonsPage> {
    this.check()
    if (this.lessonsUnsupported) throw new ApiError('not found', 404)
    this.lessonFetches++
    if (version === this.lessonsVersion) return { version, unchanged: true, items: [] }
    return { version: this.lessonsVersion, unchanged: false, items: this.lessonList }
  }
  async flagQuestion(id: string, reason?: FlagReason) {
    this.check()
    if (this.flagError) throw this.flagError
    this.flagged.push(id)
    this.flagReasons.push(reason)
  }
}

let dbCount = 0
export async function freshDb(): Promise<Db> {
  return openDb(`test-${++dbCount}-${Math.random()}`)
}

export const draftJson = {
  draft_id: 'D1',
  lesson_id: 'L1',
  type: 'single',
  stem: '读写锁的特点是什么？',
  options: ['多个读者同时持有', '只能一个读者', '写者可并行', '禁止写者'],
  answer_index: 0,
  explanation: '读者之间不互斥。',
  difficulty: 2,
  tags: ['锁'],
  source_quote: '读写锁允许多个读者同时持有锁',
  verified: false,
}

export const draft = (id = 'D1'): AgentDraft => draftFromJson({ ...draftJson, draft_id: id })

/** A scripted assistant that records what it was asked. */
export class FakeAgentApi implements AgentApi {
  statusValue: AgentStatus = { available: true, model: 'm', verified: false }
  statusError: Error | null = null
  requests: AgentChatRequest[] = []
  /** The events of the next answer; [holdOpen] then keeps the stream open until it is aborted. */
  events: AgentEvent[] = []
  holdOpen = false
  chatError: Error | null = null
  accepted: string[] = []
  discarded: string[] = []
  decideError: Error | null = null
  /** The conversations the server keeps, by id. */
  history = new Map<string, AgentConversationDetail>()
  deleted: string[] = []
  listError: Error | null = null

  /** Puts a conversation on the "server", as one that was talked in before. */
  keep(id: string, o: Partial<AgentConversationDetail> & { at?: number } = {}): AgentConversationDetail {
    const c: AgentConversationDetail = {
      id, mode: 'learn', title: `对话 ${id}`, bankId: '', lessonId: '', questionId: '', messages: [], ...o,
    }
    this.history.set(id, c)
    ;(c as AgentConversationDetail & { at: number }).at = o.at ?? this.history.size
    return c
  }

  async conversations(opts: { before?: number; limit?: number } = {}): Promise<AgentConversationPage> {
    if (this.listError) throw this.listError
    const all = [...this.history.values()] as (AgentConversationDetail & { at: number })[]
    all.sort((a, b) => b.at - a.at)
    const rows = all.filter((c) => !opts.before || c.at < opts.before)
    const take = rows.slice(0, opts.limit ?? 30)
    return {
      items: take.map((c) => ({
        id: c.id, mode: c.mode, title: c.title, bankId: c.bankId, lessonId: c.lessonId, questionId: c.questionId,
        messageCount: c.messages.length,
        pendingDrafts: c.messages.reduce((n, m) => n + m.drafts.filter((d) => d.phase === 'pending').length, 0),
        updatedAt: c.at,
      })),
      hasMore: rows.length > take.length,
    }
  }
  async conversation(id: string) {
    const c = this.history.get(id)
    if (!c) throw new AgentError('这场对话已经不存在了，可能被删除了，或服务器还不支持历史对话', 404)
    return c
  }
  async deleteConversation(id: string) {
    if (!this.history.delete(id)) throw new AgentError('not found', 404)
    this.deleted.push(id)
  }

  /** Files "on the server": uploaded and not sent yet. */
  uploads: { conversationId: string; name: string; id: string }[] = []
  removed: string[] = []
  /** Refuses the next upload with this. */
  uploadError: Error | null = null
  async uploadAttachment(conversationId: string, file: File): Promise<AgentAttachment> {
    if (this.uploadError) throw this.uploadError
    const id = `F${this.uploads.length + 1}`
    this.uploads.push({ conversationId, name: file.name, id })
    return { id, kind: 'text', name: file.name, mime: 'text/plain', size: file.size, chars: file.size }
  }
  async deleteAttachment(id: string) {
    this.removed.push(id)
  }

  async status() {
    if (this.statusError) throw this.statusError
    return this.statusValue
  }
  async *chat(request: AgentChatRequest, signal?: AbortSignal): AsyncGenerator<AgentEvent> {
    this.requests.push(request)
    if (this.chatError) throw this.chatError
    for (const e of this.events) yield e
    if (this.holdOpen) {
      await new Promise<void>((_, reject) => {
        if (signal?.aborted) return reject(new AgentError('已停止'))
        signal?.addEventListener('abort', () => reject(new AgentError('已停止')))
      })
    }
  }
  async acceptDraft(id: string) {
    if (this.decideError) throw this.decideError
    this.accepted.push(id)
  }
  async discardDraft(id: string) {
    if (this.decideError) throw this.decideError
    this.discarded.push(id)
  }
}

export const storedMessage = (o: Partial<StoredMessage> & Pick<StoredMessage, 'role' | 'text'>): StoredMessage => ({
  id: 1, tools: [], drafts: [], attachments: [], note: '', error: '', createdAt: 0, ...o,
})
