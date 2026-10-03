import { openDb, type Db } from '@/data/db'
import { ApiError, type QuizApi } from '@/data/api'
import type { AttemptDto, Bank, Question, SessionDto, SessionsPage, StateDto } from '@/data/types'

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
  flagged: string[] = []
  pageSize = 1000
  failWith: Error | null = null
  flagError: Error | null = null

  /** Saved quizzes by scope, with the server sequence of their last change. */
  sessions = new Map<string, { dto: SessionDto; seq: number }>()
  private sessionSeq = 0
  /** Behave like a server from before progress sync existed (404). */
  sessionsUnsupported = false

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
  async flagQuestion(id: string) {
    this.check()
    if (this.flagError) throw this.flagError
    this.flagged.push(id)
  }
}

let dbCount = 0
export async function freshDb(): Promise<Db> {
  return openDb(`test-${++dbCount}-${Math.random()}`)
}
