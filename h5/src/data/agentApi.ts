import {
  AgentError,
  chatRequestJson,
  conversationFromJson,
  conversationItemFromJson,
  type AgentConversationDetail,
  type AgentConversationPage,
  parseAgentSse,
  type AgentChatRequest,
  type AgentEvent,
  type AgentStatus,
} from './agentTypes'

/** The study assistant on the server. An interface so the UI can be tested without a network. */
export interface AgentApi {
  /** 401: no or wrong access token; 404: the server has no model bound to the assistant (or predates it). */
  status(): Promise<AgentStatus>
  /**
   * Streams the answer. Aborting [signal] stops the model on the server. Failures before the answer
   * starts throw an [AgentError] with the HTTP status; later ones arrive as an `error` event.
   */
  chat(request: AgentChatRequest, signal?: AbortSignal): AsyncGenerator<AgentEvent>
  /** Sends a draft to the review queue (it is not published until a reviewer approves it). */
  acceptDraft(id: string): Promise<void>
  discardDraft(id: string): Promise<void>
  /** The history of conversations, newest first; [before] is the `updatedAt` of the last one of the previous page. */
  conversations(opts?: { before?: number; limit?: number }): Promise<AgentConversationPage>
  conversation(id: string): Promise<AgentConversationDetail>
  /** Also discards the drafts nobody decided on; questions already accepted stay. */
  deleteConversation(id: string): Promise<void>
}

const OLD_SERVER = '服务器还不支持历史对话，请先更新服务端'

function messageFor(status: number, detail: string): string {
  if (status === 401) return '访问令牌不对或还没设置。到「设置」填写和后台一致的访问令牌'
  if (status === 404) return 'AI 助手还没有启用。请先到后台「AI 与模型」，给「助手」角色绑定一个 Anthropic 协议的模型'
  if (status === 409) return '这场对话还在回答上一个问题，请等它结束'
  if (status === 429) return '同时进行的对话太多了，请等上一个结束'
  if (status >= 500) return '服务器出错了，请稍后再试'
  return detail || `请求被拒绝（${status}）`
}

async function errorText(res: Response): Promise<string> {
  try {
    const j = (await res.json()) as { error?: unknown }
    return typeof j.error === 'string' ? j.error : ''
  } catch {
    return ''
  }
}

export class HttpAgentApi implements AgentApi {
  constructor(
    private readonly token: () => string,
    private readonly base = '',
  ) {}

  private async send(method: string, path: string, opts: { body?: unknown; signal?: AbortSignal; stream?: boolean } = {}) {
    const headers: Record<string, string> = { Authorization: `Bearer ${this.token()}` }
    if (opts.body !== undefined) headers['Content-Type'] = 'application/json'
    if (opts.stream) headers.Accept = 'text/event-stream'
    // A plain call gives up after 30 s; a stream is only as long as the learner lets it be (the
    // server pings every 15 s, and aborting [signal] ends it).
    const ctrl = new AbortController()
    const timer = opts.stream ? undefined : setTimeout(() => ctrl.abort(), 30_000)
    const relay = () => ctrl.abort()
    opts.signal?.addEventListener('abort', relay)
    if (opts.signal?.aborted) ctrl.abort()
    let res: Response
    try {
      res = await fetch(this.base + path, {
        method,
        headers,
        body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
        signal: ctrl.signal,
      })
    } catch (e) {
      if (opts.signal?.aborted) throw new AgentError('已停止')
      throw new AgentError(
        (e as Error).name === 'AbortError' ? '服务器长时间没有响应，请重试' : '连不上服务器，请确认地址正确并已联网',
      )
    } finally {
      clearTimeout(timer)
      if (!opts.stream) opts.signal?.removeEventListener('abort', relay)
    }
    if (!res.ok) {
      opts.signal?.removeEventListener('abort', relay)
      throw new AgentError(messageFor(res.status, await errorText(res)), res.status)
    }
    return res
  }

  async status(): Promise<AgentStatus> {
    const j = (await (await this.send('GET', '/api/v1/agent/status')).json()) as Record<string, unknown>
    return { available: j.available === true, model: typeof j.model === 'string' ? j.model : '', verified: j.verified === true }
  }

  async acceptDraft(id: string) {
    await this.send('POST', `/api/v1/agent/drafts/${encodeURIComponent(id)}/accept`)
  }

  async discardDraft(id: string) {
    await this.send('POST', `/api/v1/agent/drafts/${encodeURIComponent(id)}/discard`)
  }

  /** The history calls answer 404 for a server from before they existed; that is not "no assistant". */
  private async history<T>(call: () => Promise<T>, missing = OLD_SERVER): Promise<T> {
    try {
      return await call()
    } catch (e) {
      if (e instanceof AgentError && e.status === 404) throw new AgentError(missing, 404)
      throw e
    }
  }

  async conversations(opts: { before?: number; limit?: number } = {}): Promise<AgentConversationPage> {
    const q = new URLSearchParams()
    if (opts.before) q.set('before', String(opts.before))
    if (opts.limit) q.set('limit', String(opts.limit))
    const j = (await (await this.history(() => this.send('GET', `/api/v1/agent/conversations?${q}`))).json()) as { items?: unknown; has_more?: unknown }
    const items = Array.isArray(j.items) ? j.items.map((x) => conversationItemFromJson(x as Record<string, unknown>)) : []
    return { items, hasMore: j.has_more === true }
  }

  async conversation(id: string): Promise<AgentConversationDetail> {
    const res = await this.history(
      () => this.send('GET', `/api/v1/agent/conversations/${encodeURIComponent(id)}`),
      '这场对话已经不存在了，可能被删除了，或服务器还不支持历史对话',
    )
    return conversationFromJson((await res.json()) as Record<string, unknown>)
  }

  async deleteConversation(id: string) {
    await this.history(() => this.send('DELETE', `/api/v1/agent/conversations/${encodeURIComponent(id)}`))
  }

  async *chat(request: AgentChatRequest, signal?: AbortSignal): AsyncGenerator<AgentEvent> {
    const res = await this.send('POST', '/api/v1/agent/chat', { body: chatRequestJson(request), signal, stream: true })
    if (!res.body) throw new AgentError('服务器没有返回内容，请重试')
    try {
      yield* parseAgentSse(res.body)
    } catch (e) {
      if (e instanceof AgentError) throw e
      if (signal?.aborted) throw new AgentError('已停止')
      throw new AgentError('网络中断了，请重试')
    }
  }
}
