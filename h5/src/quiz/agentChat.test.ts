// @vitest-environment happy-dom
import { beforeEach, describe, expect, it } from 'vitest'
import { reactive } from 'vue'
import { AgentError } from '@/data/agentTypes'
import { draft, FakeAgentApi, storedMessage } from '@/test-support'
import { agentArgs } from './agentLinks'
import { AgentChat } from './agentChat'

const learn = agentArgs({ mode: 'learn', bankId: 'b1' })
const create = agentArgs({ mode: 'create', bankId: 'b1', lessonId: 'L1' })

beforeEach(() => localStorage.clear())

function make(api: FakeAgentApi, args = learn) {
  return reactive(new AgentChat(args, 'dev1', api)) as AgentChat
}

describe('AgentChat', () => {
  it('streams an answer in, shows the lookups, and sends only the new question', async () => {
    const api = new FakeAgentApi()
    api.events = [
      { kind: 'start', conversationId: 'x' },
      { kind: 'tool', id: 't1', name: 'search_lessons', label: '在讲义里查找…', status: 'running' },
      { kind: 'tool', id: 't1', name: 'search_lessons', label: '在讲义里查找…', status: 'done' },
      { kind: 'delta', text: '读写锁允许' },
      { kind: 'delta', text: '多个读者。' },
      { kind: 'done', stop: 'end_turn', inputTokens: 1, outputTokens: 2 },
    ]
    const chat = make(api)
    await chat.send('  讲讲读写锁 ')
    expect(chat.busy).toBe(false)
    expect(chat.messages.map((m) => m.role)).toEqual(['user', 'assistant'])
    expect(chat.messages[1]).toMatchObject({ text: '读写锁允许多个读者。', streaming: false })
    expect(chat.messages[1].tools).toEqual([{ id: 't1', label: '在讲义里查找…', status: 'done' }])
    expect(api.requests[0]).toMatchObject({
      conversationId: chat.conversationId,
      mode: 'learn',
      deviceId: 'dev1',
      message: { text: '讲讲读写锁' },
      context: { bankId: 'b1', lessonId: '', questionId: '' },
    })

    api.events = [{ kind: 'delta', text: '好' }, { kind: 'done', stop: 'end_turn', inputTokens: 0, outputTokens: 0 }]
    await chat.send('再讲讲')
    // The server has the first exchange; the same conversation carries on.
    expect(api.requests[1].message).toEqual({ text: '再讲讲' })
    expect(api.requests[1].conversationId).toBe(api.requests[0].conversationId)
  })

  it('a tool that never reported back is not left running', async () => {
    const api = new FakeAgentApi()
    api.events = [{ kind: 'tool', id: 't1', name: 'n', label: '查找', status: 'running' }]
    const chat = make(api)
    await chat.send('问')
    expect(chat.messages[1].tools[0].status).toBe('done')
  })

  it('ignores a send while an answer is being written, and an empty one', async () => {
    const api = new FakeAgentApi()
    api.holdOpen = true
    const chat = make(api)
    const first = chat.send('问')
    await Promise.resolve()
    expect(chat.busy).toBe(true)
    await chat.send('又问')
    await chat.send('   ')
    expect(api.requests).toHaveLength(1)
    chat.stop()
    await first
  })

  it('stop keeps what has arrived and says so, without an error', async () => {
    const api = new FakeAgentApi()
    api.events = [{ kind: 'delta', text: '写到一半' }]
    api.holdOpen = true
    const chat = make(api)
    const sent = chat.send('问')
    await new Promise((r) => setTimeout(r, 10))
    chat.stop()
    await sent
    const bot = chat.messages[chat.messages.length - 1]
    expect(bot).toMatchObject({ text: '写到一半', note: '已停止', streaming: false })
    expect(bot.error).toBeUndefined()
    expect(chat.busy).toBe(false)
  })

  it('failures before and inside the stream end up on the answer, and the next question still works', async () => {
    const api = new FakeAgentApi()
    api.chatError = new AgentError('访问令牌不对', 401)
    const chat = make(api)
    await chat.send('问')
    expect(chat.messages[1].error).toBe('访问令牌不对')
    expect(chat.busy).toBe(false)

    api.chatError = null
    api.events = [{ kind: 'delta', text: '半' }, { kind: 'error', code: 'budget_exceeded', message: '今日额度用完' }]
    await chat.send('再问')
    expect(chat.messages[3]).toMatchObject({ text: '半', error: '今日额度用完' })

    api.chatError = new Error('boom')
    await chat.send('三问')
    expect(chat.messages[5].error).toContain('boom')
  })

  it('"done" with a cut-off or too many rounds leaves a note', async () => {
    const api = new FakeAgentApi()
    api.events = [{ kind: 'delta', text: 'a' }, { kind: 'done', stop: 'max_tokens', inputTokens: 0, outputTokens: 0 }]
    const chat = make(api)
    await chat.send('问')
    expect(chat.messages[1].note).toBe('回答太长，被截断了')
    api.events = [{ kind: 'done', stop: 'max_rounds', inputTokens: 0, outputTokens: 0 }]
    await chat.send('再问')
    expect(chat.messages[3].note).toBe('查了很多资料，只能先答到这里')
  })

  it('tells the server what the learner is looking at', async () => {
    const api = new FakeAgentApi()
    const chat = make(api, agentArgs({ mode: 'learn', bankId: 'b1', questionId: 'q9', selected: [2, 0] }))
    await chat.send('为什么？')
    expect(api.requests[0].context).toEqual({ bankId: 'b1', lessonId: '', questionId: 'q9', selected: [2, 0] })
  })

  describe('drafts', () => {
    it('a drafts event adds a card under the answer', async () => {
      const api = new FakeAgentApi()
      api.events = [{ kind: 'drafts', drafts: [draft('D1'), draft('D2')] }]
      const chat = make(api, create)
      await chat.send('出题')
      expect(chat.messages[1].draftIds).toEqual(['D1', 'D2'])
      expect(chat.drafts.D1).toMatchObject({ phase: 'pending' })
    })

    it('accept and discard call the server and mark the card', async () => {
      const api = new FakeAgentApi()
      api.events = [{ kind: 'drafts', drafts: [draft('D1'), draft('D2')] }]
      const chat = make(api, create)
      await chat.send('出题')
      await chat.accept('D1')
      await chat.discard('D2')
      expect(api.accepted).toEqual(['D1'])
      expect(api.discarded).toEqual(['D2'])
      expect(chat.drafts.D1.phase).toBe('accepted')
      expect(chat.drafts.D2.phase).toBe('discarded')
    })

    it('a refusal puts the card back with the reason, so it can be tried again', async () => {
      const api = new FakeAgentApi()
      api.events = [{ kind: 'drafts', drafts: [draft('D1')] }]
      const chat = make(api, create)
      await chat.send('出题')
      api.decideError = new AgentError('这道草稿已经处理过了', 409)
      await chat.accept('D1')
      expect(chat.drafts.D1).toMatchObject({ phase: 'pending', error: '这道草稿已经处理过了' })
      api.decideError = null
      await chat.accept('D1')
      expect(chat.drafts.D1).toMatchObject({ phase: 'accepted', error: undefined })
    })

    it('a repeated drafts event does not reset a card the learner already decided on', async () => {
      const api = new FakeAgentApi()
      api.events = [{ kind: 'drafts', drafts: [draft('D1')] }]
      const chat = make(api, create)
      await chat.send('出题')
      await chat.discard('D1')
      await chat.send('再来')
      expect(chat.drafts.D1.phase).toBe('discarded')
      expect(chat.messages[3].draftIds).toEqual(['D1'])
    })

    it('the revision prompt names the draft', async () => {
      const api = new FakeAgentApi()
      api.events = [{ kind: 'drafts', drafts: [draft('D1')] }]
      const chat = make(api, create)
      await chat.send('出题')
      const p = chat.revisionPrompt('D1')
      expect(p).toContain('draft_id：D1')
      expect(p).toContain('读写锁的特点是什么？')
    })

    it('every conversation is new: no id is remembered between them', () => {
      const api = new FakeAgentApi()
      expect(make(api, create).conversationId).not.toBe(make(api, create).conversationId)
      expect(make(api).conversationId).not.toBe(make(api).conversationId)
    })
  })

  describe('a conversation read back from the server', () => {
    const stored = () => ({
      id: 'old-1', mode: 'create' as const, title: '出题', bankId: 'b1', lessonId: 'L1', questionId: '',
      messages: [
        storedMessage({ id: 1, role: 'user', text: '出 3 道题' }),
        storedMessage({
          id: 2, role: 'assistant', text: '出好了', note: '已停止',
          tools: [{ id: 't', label: '读取讲义', status: 'done' }],
          drafts: [
            { draft: draft('D1'), phase: 'accepted' },
            { draft: draft('D2'), phase: 'discarded' },
            { draft: draft('D3'), phase: 'pending' },
          ],
        }),
        storedMessage({ id: 3, role: 'user', text: '再来' }),
        storedMessage({ id: 4, role: 'assistant', text: '', error: '今日额度用完' }),
      ],
    })

    it('shows the messages, the lookups, the notes and the cards as they stood', () => {
      const chat = reactive(new AgentChat(agentArgs({ mode: 'create', bankId: 'b1', lessonId: 'L1' }), 'dev1', new FakeAgentApi(), stored())) as AgentChat
      expect(chat.conversationId).toBe('old-1')
      expect(chat.messages.map((m) => [m.role, m.text])).toEqual([['user', '出 3 道题'], ['assistant', '出好了'], ['user', '再来'], ['assistant', '']])
      expect(chat.messages[1]).toMatchObject({ note: '已停止', draftIds: ['D1', 'D2', 'D3'], streaming: false })
      expect(chat.messages[1].tools).toEqual([{ id: 't', label: '读取讲义', status: 'done' }])
      expect(chat.messages[3].error).toBe('今日额度用完')
      expect(chat.messages[0].error).toBeUndefined()
      expect(Object.entries(chat.drafts).map(([id, e]) => [id, e.phase])).toEqual([['D1', 'accepted'], ['D2', 'discarded'], ['D3', 'pending']])
    })

    it('carries on in the same conversation, and a card still waiting can be decided', async () => {
      const api = new FakeAgentApi()
      api.events = [{ kind: 'delta', text: '好' }]
      const chat = reactive(new AgentChat(agentArgs({ mode: 'create', bankId: 'b1', lessonId: 'L1' }), 'dev1', api, stored())) as AgentChat
      await chat.send('再出两道')
      expect(api.requests[0]).toMatchObject({ conversationId: 'old-1', mode: 'create', message: { text: '再出两道' }, context: { bankId: 'b1', lessonId: 'L1' } })
      expect(chat.messages).toHaveLength(6)
      await chat.accept('D3')
      expect(api.accepted).toEqual(['D3'])
      expect(chat.drafts.D3.phase).toBe('accepted')
    })
  })
})
