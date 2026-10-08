import { agentApi } from '@/core/agent'
import { newUlid } from '@/core/ulid'
import type { AgentApi } from '@/data/agentApi'
import {
  AgentError,
  type AgentConversationDetail,
  type AgentDraft,
  type AgentEvent,
  type DraftPhase as Phase,
} from '@/data/agentTypes'
import type { AgentArgs } from './agentLinks'

export interface ToolRow {
  id: string
  label: string
  status: 'running' | 'done' | 'error'
}

export interface AgentMsg {
  id: number
  role: 'user' | 'assistant'
  text: string
  tools: ToolRow[]
  /** Drafts shown as cards under this message. */
  draftIds: string[]
  streaming: boolean
  error?: string
  /** A remark about how the answer ended (stopped, cut short). */
  note?: string
}

/** A card's state: what the server says, plus `working` while a decision is on its way. */
export type DraftPhase = Phase | 'working'

export interface DraftEntry {
  draft: AgentDraft
  phase: DraftPhase
  error?: string
}

/** One conversation with the assistant. Wrap it in `reactive()` to bind it to a view. */
export class AgentChat {
  messages: AgentMsg[] = []
  drafts: Record<string, DraftEntry> = {}
  /** An answer is being written. */
  busy = false

  readonly conversationId: string
  private nextId = 1
  private abort: AbortController | null = null
  private disposed = false

  /**
   * [stored] is a conversation read back from the server, to look at it again and carry on; without
   * it a new conversation begins. The server keeps the history: only the new question is sent.
   */
  constructor(
    readonly args: AgentArgs,
    private readonly deviceId: string,
    private readonly api: AgentApi = agentApi(),
    stored?: AgentConversationDetail,
  ) {
    this.conversationId = stored?.id ?? newUlid()
    for (const m of stored?.messages ?? []) {
      this.messages.push({
        id: this.nextId++,
        role: m.role,
        text: m.text,
        tools: m.tools.map((t) => ({ ...t })),
        draftIds: m.drafts.map((d) => d.draft.id),
        streaming: false,
        error: m.error || undefined,
        note: m.note || undefined,
      })
      for (const d of m.drafts) this.drafts[d.draft.id] = { draft: d.draft, phase: d.phase }
    }
  }

  /** Stops the answer being written; what has arrived stays. */
  stop() {
    this.abort?.abort()
  }

  /** The page is left: stop the model on the server and let go of the stream. */
  dispose() {
    this.disposed = true
    this.abort?.abort()
  }

  /** Sends [text] and streams the answer in. */
  async send(text: string) {
    const t = text.trim()
    if (!t || this.busy) return
    const user: AgentMsg = { id: this.nextId++, role: 'user', text: t, tools: [], draftIds: [], streaming: false }
    const bot: AgentMsg = { id: this.nextId++, role: 'assistant', text: '', tools: [], draftIds: [], streaming: true }
    this.messages.push(user, bot)
    this.busy = true

    const abort = (this.abort = new AbortController())
    try {
      const request = {
        conversationId: this.conversationId,
        mode: this.args.mode,
        deviceId: this.deviceId,
        message: { text: t },
        context: {
          bankId: this.args.bankId,
          lessonId: this.args.lessonId,
          questionId: this.args.questionId,
          selected: this.args.selected,
        },
      }
      for await (const ev of this.api.chat(request, abort.signal)) {
        if (this.disposed) return
        this.apply(bot.id, ev)
      }
    } catch (e) {
      if (!this.disposed) {
        if (abort.signal.aborted) this.patch(bot.id, (m) => (m.note = '已停止'))
        else this.patch(bot.id, (m) => (m.error = e instanceof AgentError ? e.message : `出错了：${(e as Error).message ?? e}`))
      }
    } finally {
      if (!this.disposed) {
        this.patch(bot.id, (m) => {
          m.streaming = false
          // A tool that never reported back is not still running.
          for (const r of m.tools) if (r.status === 'running') r.status = 'done'
        })
        this.busy = false
      }
      if (this.abort === abort) this.abort = null
    }
  }

  private patch(id: number, change: (m: AgentMsg) => void) {
    const m = this.messages.find((x) => x.id === id)
    if (m) change(m)
  }

  private apply(id: number, ev: AgentEvent) {
    switch (ev.kind) {
      case 'start':
        break
      case 'delta':
        this.patch(id, (m) => (m.text += ev.text))
        break
      case 'tool':
        this.patch(id, (m) => {
          const row: ToolRow = { id: ev.id, label: ev.label, status: ev.status }
          const at = m.tools.findIndex((r) => r.id === ev.id)
          if (at < 0) m.tools.push(row)
          else m.tools[at] = row
        })
        break
      case 'drafts':
        // A card the learner already decided on is not reset by a repeated event.
        for (const d of ev.drafts) this.drafts[d.id] ??= { draft: d, phase: 'pending' }
        this.patch(id, (m) => {
          for (const d of ev.drafts) if (!m.draftIds.includes(d.id)) m.draftIds.push(d.id)
        })
        break
      case 'done':
        if (ev.stop === 'max_tokens') this.patch(id, (m) => (m.note = '回答太长，被截断了'))
        if (ev.stop === 'max_rounds') this.patch(id, (m) => (m.note = '查了很多资料，只能先答到这里'))
        break
      case 'error':
        this.patch(id, (m) => (m.error = ev.message))
        break
    }
  }

  // ---- drafts ----

  /** Sends the draft to the review queue; a reviewer still has to approve it before anyone practises it. */
  accept(draftId: string) {
    return this.decide(draftId, true)
  }

  discard(draftId: string) {
    return this.decide(draftId, false)
  }

  private async decide(id: string, accept: boolean) {
    const entry = this.drafts[id]
    if (!entry || entry.phase === 'working') return
    entry.phase = 'working'
    entry.error = undefined
    try {
      if (accept) await this.api.acceptDraft(id)
      else await this.api.discardDraft(id)
      if (!this.disposed) entry.phase = accept ? 'accepted' : 'discarded'
    } catch (e) {
      if (this.disposed) return
      entry.phase = 'pending'
      entry.error = e instanceof AgentError ? e.message : `出错了：${(e as Error).message ?? e}`
    }
  }

  /**
   * The words that start a request to rewrite a draft; the learner finishes the sentence. The id lets
   * the assistant replace exactly that draft.
   */
  revisionPrompt(draftId: string): string {
    const d = this.drafts[draftId]?.draft
    const stem = d ? d.stem.replace(/\s+/g, ' ') : ''
    const shown = [...stem].length > 30 ? `${[...stem].slice(0, 30).join('')}…` : stem
    return `请修改这道草稿（draft_id：${draftId}，题干：「${shown}」）：`
  }
}
