// @vitest-environment happy-dom
import { afterEach, describe, expect, it, vi } from 'vitest'
import { HttpAgentApi } from './agentApi'
import { AgentError, draftFromJson, parseAgentSse, type AgentEvent } from './agentTypes'
import { draftJson } from '@/test-support'

const enc = new TextEncoder()
function stream(parts: string[]): ReadableStream<Uint8Array> {
  return new ReadableStream({
    start(c) {
      for (const p of parts) c.enqueue(enc.encode(p))
      c.close()
    },
  })
}
const ev = (name: string, data: unknown) => `event: ${name}\ndata: ${JSON.stringify(data)}\n\n`
async function all(body: ReadableStream<Uint8Array>) {
  const out: AgentEvent[] = []
  for await (const e of parseAgentSse(body)) out.push(e)
  return out
}

describe('parseAgentSse', () => {
  it('reads named events, skips pings and unknown events, and copes with split chunks', async () => {
    const whole = [
      ': ping\n\n',
      ev('start', { conversation_id: 'c1' }),
      ev('delta', { text: '读写锁' }),
      ev('future', { x: 1 }),
      ev('tool', { id: 't1', name: 'search_lessons', label: '在讲义里查找…', status: 'running' }),
      ev('tool', { id: 't1', name: 'search_lessons', label: '在讲义里查找…', status: 'done' }),
      ev('drafts', { drafts: [draftJson] }),
      ev('done', { stop: 'end_turn', usage: { input: 10, output: 5 } }),
    ].join('')
    // Cut in the middle of an event name and of a multi-byte character.
    const bytes = enc.encode(whole)
    const cut = (n: number) => new ReadableStream<Uint8Array>({
      start(c) {
        c.enqueue(bytes.slice(0, n))
        c.enqueue(bytes.slice(n))
        c.close()
      },
    })
    const a = await all(stream([whole]))
    expect(a.map((e) => e.kind)).toEqual(['start', 'delta', 'tool', 'tool', 'drafts', 'done'])
    for (const n of [7, 40, 61, 100]) expect(await all(cut(n))).toEqual(a)
    expect(a[1]).toEqual({ kind: 'delta', text: '读写锁' })
    expect(a[3]).toMatchObject({ kind: 'tool', status: 'done' })
    expect(a[4]).toMatchObject({ kind: 'drafts', drafts: [{ id: 'D1', answerIndex: 0, verified: false }] })
    expect(a[5]).toEqual({ kind: 'done', stop: 'end_turn', inputTokens: 10, outputTokens: 5 })
  })

  it('accepts CRLF, drops events whose data is not JSON, and reads a last event without a blank line', async () => {
    const out = await all(stream(['event: delta\r\ndata: {"text":"a"}\r\n\r\n', 'event: delta\ndata: {oops\n\n', 'event: delta\ndata: {"text":"b"}']))
    expect(out).toEqual([
      { kind: 'delta', text: 'a' },
      { kind: 'delta', text: 'b' },
    ])
  })

  it('maps an error event, and fills in what a sparse one leaves out', async () => {
    const out = await all(stream([ev('error', { code: 'budget_exceeded', message: '今日额度用完' }), ev('error', {}), ev('done', {})]))
    expect(out).toEqual([
      { kind: 'error', code: 'budget_exceeded', message: '今日额度用完' },
      { kind: 'error', code: 'internal', message: '助手出错了' },
      { kind: 'done', stop: 'end_turn', inputTokens: 0, outputTokens: 0 },
    ])
  })
})

describe('HttpAgentApi', () => {
  afterEach(() => vi.unstubAllGlobals())
  const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
  const stub = (handler: (url: string, init: RequestInit) => Response | Promise<Response>) => {
    const calls: { url: string; init: RequestInit }[] = []
    vi.stubGlobal('fetch', async (url: string, init: RequestInit) => {
      calls.push({ url, init })
      return handler(url, init)
    })
    return calls
  }
  const api = new HttpAgentApi(() => 'tok')

  it('sends the token with every call and reads the status', async () => {
    const calls = stub(() => json({ available: true, model: 'deepseek', verified: true, vision: true }))
    expect(await api.status()).toEqual({ available: true, model: 'deepseek', verified: true, vision: true })
    expect(calls[0].url).toBe('/api/v1/agent/status')
    expect((calls[0].init.headers as Record<string, string>).Authorization).toBe('Bearer tok')
  })

  it('leaves the mode out unless one is asked for: the whole assistant', async () => {
    const calls = stub(() => new Response(stream([ev('done', { stop: 'end_turn' })]), { status: 200 }))
    for await (const _ of api.chat({ conversationId: 'c1', deviceId: 'd1', message: { text: '讲讲' }, context: {} })) void _
    expect(JSON.parse(calls[0].init.body as string)).not.toHaveProperty('mode')
  })

  it('reads whether a question was adopted when it was written', () => {
    expect(draftFromJson({ ...draftJson, adopted: true }).adopted).toBe(true)
    expect(draftFromJson({ ...draftJson }).adopted).toBe(false)
  })

  it('posts the request and streams the events', async () => {
    const calls = stub(() => new Response(stream([ev('delta', { text: '好' }), ev('done', { stop: 'end_turn' })]), { status: 200 }))
    const out: AgentEvent[] = []
    for await (const e of api.chat({
      conversationId: 'c1',
      mode: 'learn',
      deviceId: 'd1',
      message: { text: '讲讲' },
      context: { bankId: 'b1', questionId: 'q1', selected: [2] },
    })) out.push(e)
    expect(out.map((e) => e.kind)).toEqual(['delta', 'done'])
    expect(calls[0].url).toBe('/api/v1/agent/chat')
    expect((calls[0].init.headers as Record<string, string>).Accept).toBe('text/event-stream')
    expect(JSON.parse(calls[0].init.body as string)).toEqual({
      conversation_id: 'c1',
      mode: 'learn',
      device_id: 'd1',
      message: { text: '讲讲', attachment_ids: [] },
      context: { bank_id: 'b1', question: { id: 'q1', selected: [2] } },
    })
  })

  it('answers before the stream starts become messages the learner can act on', async () => {
    const run = async (status: number, body: unknown = {}) => {
      stub(() => json(body, status))
      const err = await api.status().catch((e) => e)
      expect(err).toBeInstanceOf(AgentError)
      return err as AgentError
    }
    expect(await run(401)).toMatchObject({ status: 401, message: expect.stringContaining('访问令牌') })
    expect(await run(404)).toMatchObject({ status: 404, message: expect.stringContaining('还没有启用') })
    expect(await run(429)).toMatchObject({ message: expect.stringContaining('同时进行') })
    expect(await run(503)).toMatchObject({ message: expect.stringContaining('服务器出错') })
    expect(await run(400, { error: '消息太长' })).toMatchObject({ message: '消息太长' })

    vi.stubGlobal('fetch', () => Promise.reject(new TypeError('offline')))
    expect((await api.status().catch((e) => e)).message).toContain('连不上服务器')
  })

  it('an abort ends the stream as "stopped"', async () => {
    vi.stubGlobal('fetch', (_: string, init: RequestInit) => new Promise((_, reject) => {
      init.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')))
    }))
    const ctrl = new AbortController()
    const run = (async () => {
      for await (const _ of api.chat({ conversationId: 'c', mode: 'learn', deviceId: 'd', message: { text: 'x' }, context: {} }, ctrl.signal)) void _
    })()
    ctrl.abort()
    await expect(run).rejects.toMatchObject({ message: '已停止' })
  })

  it('lists the conversations, reads one back, and deletes one', async () => {
    const calls = stub((url) => {
      if (url.includes('/conversations?')) {
        return json({
          items: [{ id: 'c1', mode: 'create', title: '出题', bank_id: 'b1', lesson_id: '', question_id: '', message_count: 2, pending_drafts: 1, updated_at: 99 }],
          has_more: true,
        })
      }
      if (url.endsWith('/conversations/c%201')) {
        return json({
          id: 'c 1', mode: 'create', title: '出题', bank_id: 'b1', lesson_id: 'L1', question_id: '', updated_at: 99,
          messages: [
            { id: 1, role: 'user', text: '出一道题', tools: [], drafts: [], note: '', error: '', created_at: 1 },
            {
              id: 2, role: 'assistant', text: '好', created_at: 2, note: '已停止', error: '',
              tools: [{ id: 't', label: '查找', status: 'done' }],
              drafts: [{ ...draftJson, phase: 'accepted' }, { ...draftJson, draft_id: 'D2', phase: 'weird' }],
            },
          ],
        })
      }
      return json({})
    })
    const page = await api.conversations({ before: 120, limit: 10 })
    expect(calls[0].url).toBe('/api/v1/agent/conversations?before=120&limit=10')
    expect(page).toEqual({
      hasMore: true,
      items: [{ id: 'c1', mode: 'create', title: '出题', bankId: 'b1', lessonId: '', questionId: '', messageCount: 2, pendingDrafts: 1, updatedAt: 99 }],
    })

    const c = await api.conversation('c 1')
    expect(c).toMatchObject({ id: 'c 1', mode: 'create', bankId: 'b1', lessonId: 'L1' })
    expect(c.messages[1]).toMatchObject({ role: 'assistant', note: '已停止', tools: [{ id: 't', status: 'done' }] })
    expect(c.messages[1].drafts.map((d) => [d.draft.id, d.phase])).toEqual([['D1', 'accepted'], ['D2', 'pending']])

    await api.deleteConversation('c 1')
    expect(calls[calls.length - 1].init.method).toBe('DELETE')
    expect(calls[calls.length - 1].url).toBe('/api/v1/agent/conversations/c%201')
  })

  it('a server from before history says so, instead of "the assistant is not enabled"', async () => {
    stub(() => json({ error: 'not found' }, 404))
    for (const call of [() => api.conversations(), () => api.deleteConversation('c')]) {
      const e = await call().catch((x) => x)
      expect(e).toBeInstanceOf(AgentError)
      expect(e.message).toContain('更新服务端')
      expect(e.message).not.toContain('助手')
    }
    const gone = await api.conversation('c').catch((x) => x)
    expect(gone.message).toContain('已经不存在')
  })

  it('a conversation that is still being answered is a message, not a crash', async () => {
    stub(() => json({}, 409))
    expect(await api.deleteConversation('c1').catch((e) => e)).toMatchObject({ status: 409, message: expect.stringContaining('还在回答') })
  })

  it('accept and discard use the right paths', async () => {
    const calls = stub(() => json({}))
    await api.acceptDraft('D/1')
    await api.discardDraft('D2')
    expect(calls.map((c) => `${c.init.method} ${c.url}`)).toEqual([
      'POST /api/v1/agent/drafts/D%2F1/accept',
      'POST /api/v1/agent/drafts/D2/discard',
    ])
  })

  it('reads a status from a server that does not know about pictures as "cannot see"', async () => {
    stub(() => json({ available: true, model: 'm', verified: false }))
    expect((await api.status()).vision).toBe(false)
  })

  it('fetches a picture with the token', async () => {
    const calls = stub(() => new Response(new Blob(['png'], { type: 'image/png' }), { status: 200 }))
    const b = await api.attachmentBlob('A/1')
    expect(b.type).toBe('image/png')
    expect(calls[0].url).toBe('/api/v1/agent/attachments/A%2F1')
    expect((calls[0].init.headers as Record<string, string>).Authorization).toBe('Bearer tok')
  })

  it('uploads a file as a form with the conversation, and removes one', async () => {
    const calls = stub((_url, init) =>
      init.method === 'POST'
        ? json({ id: 'F1', kind: 'text', name: '笔记.md', mime: 'text/markdown', size: 6, chars: 2 }, 201)
        : new Response(null, { status: 204 }),
    )
    const a = await api.uploadAttachment('c1', new File(['# 笔记'], '笔记.md'))
    expect(a).toEqual({ id: 'F1', kind: 'text', name: '笔记.md', mime: 'text/markdown', size: 6, chars: 2, width: 0, height: 0 })
    expect(calls[0].url).toBe('/api/v1/agent/attachments')
    const h = calls[0].init.headers as Record<string, string>
    expect(h.Authorization).toBe('Bearer tok')
    expect(h['Content-Type']).toBeUndefined() // the browser adds it, with the boundary
    const form = calls[0].init.body as FormData
    expect(form.get('conversation_id')).toBe('c1')
    expect((form.get('file') as File).name).toBe('笔记.md')

    await api.deleteAttachment('F/1')
    expect(`${calls[1].init.method} ${calls[1].url}`).toBe('DELETE /api/v1/agent/attachments/F%2F1')
  })

  it("an upload's refusal is shown as the server worded it; an old server is named", async () => {
    stub(() => json({ error: '一场对话最多 8 个文件' }, 400))
    await expect(api.uploadAttachment('c1', new File(['x'], 'a.md'))).rejects.toMatchObject({ message: '一场对话最多 8 个文件', status: 400 })
    stub(() => json({ error: 'not found' }, 404))
    await expect(api.uploadAttachment('c1', new File(['x'], 'a.md'))).rejects.toMatchObject({ message: expect.stringContaining('更新服务端') })
    stub(() => new Response('', { status: 413 }))
    await expect(api.uploadAttachment('c1', new File(['x'], 'a.md'))).rejects.toMatchObject({ message: expect.stringContaining('太大') })
  })

  it('reads the files of a stored conversation', async () => {
    stub(() =>
      json({
        id: 'c1', mode: 'learn', title: 't', messages: [
          { id: 1, role: 'user', text: '看', attachments: [{ id: 'A1', kind: 'text', name: 'n.md', mime: 'text/markdown', size: 3, chars: 3 }] },
          { id: 2, role: 'assistant', text: '好' },
        ],
      }),
    )
    const c = await api.conversation('c1')
    expect(c.messages[0].attachments).toEqual([{ id: 'A1', kind: 'text', name: 'n.md', mime: 'text/markdown', size: 3, chars: 3, width: 0, height: 0 }])
    expect(c.messages[1].attachments).toEqual([])
  })
})
