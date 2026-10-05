import type {
  AttemptDto,
  AttemptsPage,
  Bank,
  ExamRecord,
  ExamsPage,
  FlagReason,
  QuestionsPage,
  SessionDto,
  SessionsPage,
  StateDto,
  StatesPage,
} from './types'

/** Thrown for any failed call; message is safe to show to the user. */
export class ApiError extends Error {
  constructor(
    message: string,
    readonly status?: number,
  ) {
    super(message)
  }
}

/** The server operations the app needs; an interface so sync can be tested offline. */
export interface QuizApi {
  banks(): Promise<Bank[]>
  syncQuestions(since: number, limit?: number): Promise<QuestionsPage>
  syncStates(since: number, limit?: number): Promise<StatesPage>
  uploadAttempts(attempts: AttemptDto[]): Promise<void>
  /** The whole answer log, from every device. A server from before this existed answers 404. */
  syncAttempts(since: number, limit?: number): Promise<AttemptsPage>
  /** Finished mock exams. A server from before this existed answers 404. */
  syncExams(since: number, limit?: number): Promise<ExamsPage>
  uploadExams(exams: ExamRecord[]): Promise<void>
  uploadStates(states: StateDto[]): Promise<void>
  /** Saved quizzes. A server from before the feature answers 404, which callers treat as "not supported". */
  syncSessions(since: number, limit?: number): Promise<SessionsPage>
  uploadSessions(sessions: SessionDto[]): Promise<void>
  /** The reason is optional on the server: one from before reasons existed ignores it. */
  flagQuestion(id: string, reason?: FlagReason): Promise<void>
}

export class HttpApi implements QuizApi {
  constructor(private readonly base = '') {}

  private async req<T>(method: string, path: string, body?: unknown): Promise<T> {
    const ctrl = new AbortController()
    const timer = setTimeout(() => ctrl.abort(), 30_000)
    const headers: Record<string, string> = {}
    if (body !== undefined) headers['Content-Type'] = 'application/json'
    let res: Response
    try {
      res = await fetch(this.base + path, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: ctrl.signal,
      })
    } catch (e) {
      throw new ApiError(
        (e as Error).name === 'AbortError' ? '服务器响应超时' : '连不上服务器，请确认手机和 Mac 在同一个 Wi-Fi',
      )
    } finally {
      clearTimeout(timer)
    }
    if (!res.ok) {
      let msg = `服务器返回 ${res.status}`
      try {
        const j = (await res.json()) as { error?: string }
        if (j.error) msg = j.error
      } catch {
        /* not JSON */
      }
      throw new ApiError(msg, res.status)
    }
    return (await res.json()) as T
  }

  banks() {
    return this.req<Bank[]>('GET', '/api/v1/banks')
  }
  syncQuestions(since: number, limit = 500) {
    return this.req<QuestionsPage>('GET', `/api/v1/sync/questions?since=${since}&limit=${limit}`)
  }
  syncStates(since: number, limit = 500) {
    return this.req<StatesPage>('GET', `/api/v1/sync/states?since=${since}&limit=${limit}`)
  }
  async uploadAttempts(attempts: AttemptDto[]) {
    await this.req('POST', '/api/v1/sync/attempts', attempts)
  }
  syncAttempts(since: number, limit = 500) {
    return this.req<AttemptsPage>('GET', `/api/v1/sync/attempts?since=${since}&limit=${limit}`)
  }
  syncExams(since: number, limit = 100) {
    return this.req<ExamsPage>('GET', `/api/v1/sync/exams?since=${since}&limit=${limit}`)
  }
  async uploadExams(exams: ExamRecord[]) {
    await this.req('POST', '/api/v1/sync/exams', exams)
  }
  async uploadStates(states: StateDto[]) {
    await this.req('POST', '/api/v1/sync/states', states)
  }
  syncSessions(since: number, limit = 100) {
    return this.req<SessionsPage>('GET', `/api/v1/sync/sessions?since=${since}&limit=${limit}`)
  }
  async uploadSessions(sessions: SessionDto[]) {
    await this.req('POST', '/api/v1/sync/sessions', sessions)
  }
  async flagQuestion(id: string, reason?: FlagReason) {
    await this.req('POST', `/api/v1/questions/${encodeURIComponent(id)}/flag`, reason ? { reason } : undefined)
  }
}
