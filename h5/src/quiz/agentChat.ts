import { agentApi } from '@/core/agent'
import { newUlid } from '@/core/ulid'
import type { AgentApi } from '@/data/agentApi'
import {
  ATTACH_EXTENSIONS,
  ATTACH_IMAGE_EXTENSIONS,
  ATTACH_IMAGE_MAX_BYTES,
  ATTACH_IMAGE_TYPES,
  ATTACH_MAX_BYTES,
  ATTACH_MAX_FILES,
  ATTACH_MAX_IMAGES,
  ATTACH_MAX_PER_MESSAGE,
  AgentError,
  type AgentAttachment,
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
  /** The files this message carried. */
  attachments: AgentAttachment[]
}

/** A file chosen for the next message: on its way to the server, or kept there waiting to be sent. */
export interface PendingFile {
  key: number
  name: string
  size: number
  kind: 'text' | 'image'
  /** Pictures: an address to show it by while it is still only on this device. */
  preview?: string
  status: 'uploading' | 'ready' | 'error'
  attachment?: AgentAttachment
  /** Why the file was not taken. */
  error?: string
}

/** The words sent when a file comes with no question. */
export const FILE_ONLY_TEXT = '请看一下我给你的文件。'

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
  /** Files chosen for the next message. */
  files: PendingFile[] = []
  /** The assistant's model can look at pictures (from the status); pictures are turned away without it. */
  vision = false

  readonly conversationId: string
  private nextId = 1
  private nextFile = 1
  /** Picture addresses by attachment id, made once: from the file chosen here, or fetched from the server. */
  private images = new Map<string, Promise<string>>()
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
        attachments: m.attachments.map((a) => ({ ...a })),
      })
      for (const d of m.drafts) this.drafts[d.draft.id] = { draft: d.draft, phase: d.phase }
    }
  }

  // ---- files ----

  /** Files this conversation holds: the ones sent before and the ones chosen now. */
  get fileCount(): number {
    const sent = this.messages.reduce((n, m) => n + m.attachments.length, 0)
    return sent + this.files.filter((f) => f.status !== 'error').length
  }

  /** Pictures this conversation holds, sent or chosen. */
  get imageCount(): number {
    const sent = this.messages.reduce((n, m) => n + m.attachments.filter((a) => a.kind === 'image').length, 0)
    return sent + this.files.filter((f) => f.kind === 'image' && f.status !== 'error').length
  }

  /** Another file may be added. */
  get canAttach(): boolean {
    return this.fileCount < ATTACH_MAX_FILES && this.files.filter((f) => f.status !== 'error').length < ATTACH_MAX_PER_MESSAGE
  }

  /** Another picture may be added: the model sees them, and there is room. */
  get canAttachImage(): boolean {
    return this.vision && this.canAttach && this.imageCount < ATTACH_MAX_IMAGES
  }

  get uploading(): boolean {
    return this.files.some((f) => f.status === 'uploading')
  }

  get readyFiles(): PendingFile[] {
    return this.files.filter((f) => f.status === 'ready')
  }

  private static extOf(file: File): string {
    const dot = file.name.lastIndexOf('.')
    return dot < 0 ? '' : file.name.slice(dot).toLowerCase()
  }

  private static isImage(file: File): boolean {
    return ATTACH_IMAGE_TYPES.includes(file.type) || ATTACH_IMAGE_EXTENSIONS.includes(AgentChat.extOf(file))
  }

  /** Why [file] cannot be taken, judged before uploading; the server checks again. */
  private refusal(file: File): string {
    if (file.size === 0) return '这个文件是空的'
    if (AgentChat.isImage(file)) {
      if (!this.vision) return '当前助手模型不支持识别图片'
      if (file.size > ATTACH_IMAGE_MAX_BYTES) return `图片太大了（超过 ${ATTACH_IMAGE_MAX_BYTES / 1024 / 1024} MB），请压缩或裁剪后再上传`
      if (this.imageCount >= ATTACH_MAX_IMAGES) return `一场对话最多 ${ATTACH_MAX_IMAGES} 张图片`
    } else {
      if (!ATTACH_EXTENSIONS.includes(AgentChat.extOf(file))) return `不支持这种文件，可以上传 ${ATTACH_EXTENSIONS.join(' ')} 文本文件`
      if (file.size > ATTACH_MAX_BYTES) return `文件太大了（超过 ${ATTACH_MAX_BYTES / 1024} KB），请截取需要的部分再上传`
    }
    if (!this.canAttach) return `一场对话最多 ${ATTACH_MAX_FILES} 个文件，一条消息最多带 ${ATTACH_MAX_PER_MESSAGE} 个`
    return ''
  }

  /** Uploads [file] for the next message. A file that is not taken stays in the list with the reason, until dismissed. */
  async addFile(file: File) {
    const key = this.nextFile++
    const why = this.refusal(file)
    const kind = AgentChat.isImage(file) ? 'image' : 'text'
    const preview = !why && kind === 'image' && typeof URL.createObjectURL === 'function' ? URL.createObjectURL(file) : undefined
    this.files.push({ key, name: file.name, size: file.size, kind, preview, status: why ? 'error' : 'uploading', error: why || undefined })
    if (why) return
    const set = (change: (f: PendingFile) => void) => {
      const f = this.files.find((x) => x.key === key)
      if (f) change(f)
    }
    try {
      const a = await this.api.uploadAttachment(this.conversationId, file)
      if (this.disposed) return
      if (preview) this.images.set(a.id, Promise.resolve(preview)) // shown from here once it is sent
      set((f) => {
        f.status = 'ready'
        f.attachment = a
      })
    } catch (e) {
      if (this.disposed) return
      if (preview) URL.revokeObjectURL(preview)
      set((f) => {
        f.status = 'error'
        f.preview = undefined
        f.error = e instanceof AgentError ? e.message : `出错了：${(e as Error).message ?? e}`
      })
    }
  }

  /** The address to show a picture by. Fetched from the server unless it was chosen on this device. */
  imageUrl(id: string): Promise<string> {
    let url = this.images.get(id)
    if (!url) {
      url = this.api.attachmentBlob(id).then((b) => URL.createObjectURL(b))
      this.images.set(id, url)
      url.catch(() => this.images.delete(id)) // a failed fetch may be tried again
    }
    return url
  }

  /** Takes a file off the next message and, if it reached the server, removes it there. */
  async removeFile(key: number) {
    const at = this.files.findIndex((f) => f.key === key)
    if (at < 0) return
    const [f] = this.files.splice(at, 1)
    if (f.preview) {
      URL.revokeObjectURL(f.preview)
      if (f.attachment) this.images.delete(f.attachment.id)
    }
    if (f.attachment) {
      try {
        await this.api.deleteAttachment(f.attachment.id)
      } catch {
        /* the server drops unsent files after a day anyway */
      }
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
    for (const url of this.images.values()) void url.then((u) => URL.revokeObjectURL(u), () => {})
    this.images.clear()
  }

  /** Sends [text] and streams the answer in. */
  async send(text: string) {
    const sending = this.readyFiles
    const t = text.trim() || (sending.length ? FILE_ONLY_TEXT : '')
    if (!t || this.busy || this.uploading) return
    const attachments = sending.map((f) => ({ ...f.attachment! }))
    const user: AgentMsg = { id: this.nextId++, role: 'user', text: t, tools: [], draftIds: [], streaming: false, attachments }
    const bot: AgentMsg = { id: this.nextId++, role: 'assistant', text: '', tools: [], draftIds: [], streaming: true, attachments: [] }
    // Files that were not taken are not sent; they leave with the message that carried the good ones.
    this.files = []
    this.messages.push(user, bot)
    this.busy = true

    const abort = (this.abort = new AbortController())
    try {
      const request = {
        conversationId: this.conversationId,
        mode: this.args.mode,
        deviceId: this.deviceId,
        message: { text: t, attachmentIds: attachments.map((a) => a.id) },
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
