<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import DraftCard from '@/components/DraftCard.vue'
import LessonBody from '@/components/LessonBody.vue'
import Md from '@/components/Md.vue'
import { agentApi, agentSettings } from '@/core/agent'
import { getRepo, settings, showToast } from '@/core/app'
import { ATTACH_EXTENSIONS, AgentError, type AgentStatus } from '@/data/agentTypes'
import type { Lesson, LocalQuestion } from '@/data/types'
import { AgentChat } from '@/quiz/agentChat'
import { agentArgs, agentQuery, argsFromQuery, parseAgentLink } from '@/quiz/agentLinks'
import { lessonTitle } from '@/quiz/lessons'

const route = useRoute()
const router = useRouter()

// Which conversation this page shows: a stored one (`?conversation=`), or a new one for the page the
// learner came from. The page is reused when only the query changes, so it starts over then.
const chat = ref<AgentChat>(reactive(new AgentChat(argsFromQuery(route.query).args, settings.deviceId)) as AgentChat)
const args = computed(() => chat.value.args)
const isCreate = computed(() => args.value.mode === 'create')
const input = ref(argsFromQuery(route.query).text)
const inputEl = ref<HTMLTextAreaElement | null>(null)
/** Opening a stored conversation: loading, or why it could not be opened. */
const opening = ref(false)
const openError = ref('')

async function begin() {
  chat.value.dispose()
  openError.value = ''
  const id = typeof route.query.conversation === 'string' ? route.query.conversation : ''
  if (!id) {
    const { args, text } = argsFromQuery(route.query)
    chat.value = reactive(new AgentChat(args, settings.deviceId)) as AgentChat
    input.value = text
    return
  }
  opening.value = true
  try {
    const stored = await agentApi().conversation(id)
    const args = agentArgs({ mode: stored.mode, bankId: stored.bankId, lessonId: stored.lessonId, questionId: stored.questionId })
    chat.value = reactive(new AgentChat(args, settings.deviceId, undefined, stored)) as AgentChat
    input.value = ''
    await nextTick()
    window.scrollTo(0, document.body.scrollHeight)
  } catch (e) {
    openError.value = e instanceof AgentError ? e.message : String(e)
  } finally {
    opening.value = false
  }
}

// ---- whether the assistant can be used ----
const status = ref<AgentStatus | null>(null)
const statusError = ref<AgentError | null>(null)
const hasToken = computed(() => agentSettings.token.length > 0)
let statusSeq = 0

async function loadStatus() {
  const seq = ++statusSeq
  status.value = null
  statusError.value = null
  if (!hasToken.value) return
  try {
    const s = await agentApi().status()
    if (seq === statusSeq) status.value = s
  } catch (e) {
    if (seq === statusSeq) statusError.value = e instanceof AgentError ? e : new AgentError(String(e))
  }
}
const ready = computed(() => hasToken.value && !!status.value?.available)

const banner = computed<{ message: string; action?: 'settings' | 'retry' } | null>(() => {
  if (!hasToken.value) return { message: '还没有填访问令牌。到「设置」填写后台设置的访问令牌。', action: 'settings' }
  const e = statusError.value
  if (e) return { message: e.message, action: e.status === 401 ? 'settings' : e.status === 404 ? undefined : 'retry' }
  if (status.value && !status.value.available) return { message: 'AI 助手暂时不可用' }
  return null
})
function bannerAction() {
  if (banner.value?.action === 'settings') void router.push('/settings')
  else void loadStatus()
}

onMounted(() => {
  void loadStatus()
  if (route.query.conversation) void begin()
})
watch(() => agentSettings.token, loadStatus)
// Another conversation in the same page (the history, or "new conversation").
watch(
  () => route.fullPath,
  () => {
    if (route.path === '/agent') void begin()
  },
)
onBeforeUnmount(() => chat.value.dispose())

function newConversation() {
  // The same starting point as this conversation had, without the old messages.
  const { bankId, lessonId, questionId, mode } = args.value
  const fresh = agentArgs({ mode, bankId, lessonId, questionId })
  chat.value.dispose()
  chat.value = reactive(new AgentChat(fresh, settings.deviceId)) as AgentChat
  input.value = ''
  openError.value = ''
  // A stored conversation is named in the address; the new one is not.
  if (route.query.conversation) void router.replace({ path: '/agent', query: agentQuery(fresh) })
}
const openHistory = () => router.push('/agent/history')

// ---- the conversation ----
const prompts = computed(() => {
  if (isCreate.value) return ['出 5 道单选题', '出 3 道判断题', '出几道偏难的题']
  if (args.value.questionId) return ['为什么我选的不对？', '再讲细一点', '举个例子帮我记住']
  if (args.value.lessonId) return ['讲一下这一节', '这一节有哪些考点？', '出几道题考考我']
  return ['我哪里比较薄弱？', '帮我安排一下复习顺序', '出几道题考考我']
})

// ---- files ----
const fileEl = ref<HTMLInputElement | null>(null)
const accept = ATTACH_EXTENSIONS.join(',')
function pickFile() {
  fileEl.value?.click()
}
function onFiles(e: Event) {
  const el = e.target as HTMLInputElement
  for (const f of Array.from(el.files ?? [])) void chat.value.addFile(f)
  el.value = '' // the same file can be chosen again
}
const kb = (n: number) => (n < 1024 ? `${n} B` : `${Math.round(n / 1024)} KB`)
const canSend = computed(
  () => ready.value && !chat.value.busy && !chat.value.uploading && (!!input.value.trim() || chat.value.readyFiles.length > 0),
)

function send(text?: string) {
  const t = (text ?? input.value).trim()
  if ((!t && !chat.value.readyFiles.length) || chat.value.busy || chat.value.uploading || !ready.value) return
  input.value = ''
  void chat.value.send(t)
}

function revise(draftId: string) {
  input.value = chat.value.revisionPrompt(draftId)
  void nextTick(() => inputEl.value?.focus())
}

function onEnter(e: KeyboardEvent) {
  // Enter sends on a computer; on a phone it is a line break, and the button sends. A key that
  // confirms Chinese input (isComposing) must not send.
  if (e.isComposing || e.shiftKey) return
  const touch = typeof window.matchMedia === 'function' && window.matchMedia('(pointer: coarse)').matches
  if (touch) return
  e.preventDefault()
  send()
}

// Follow the answer as it is written, unless the learner scrolled up to read something.
watch(
  () => chat.value.messages,
  async () => {
    const el = document.scrollingElement
    const nearEnd = !el || el.scrollHeight - el.scrollTop - el.clientHeight < 160
    await nextTick()
    if (nearEnd) window.scrollTo(0, document.body.scrollHeight)
  },
  { deep: true },
)

// ---- links in an answer: the section or question it points at, in a sheet over the chat ----
const lessonSheet = ref<Lesson | null>(null)
const questionSheet = ref<LocalQuestion | null>(null)

async function openLink(href: string) {
  const link = parseAgentLink(href)
  if (!link) return
  const repo = await getRepo()
  if (link.kind === 'lesson') {
    const l = await repo.lesson(link.id)
    if (l) lessonSheet.value = l
    else showToast('这一节在本机找不到，先同步一下再试')
  } else {
    const q = await repo.db.get('questions', link.id)
    if (q) questionSheet.value = q
    else showToast('这道题在本机找不到，先同步一下再试')
  }
}
</script>

<template>
  <header class="topbar">
    <button class="icon-btn" aria-label="返回" @click="router.back()">‹</button>
    <h1>{{ isCreate ? 'AI 出题' : '问 AI' }}</h1>
    <button v-if="chat.messages.length" class="icon-btn" aria-label="新对话" data-testid="agent-new" @click="newConversation">＋</button>
    <button class="icon-btn" aria-label="历史对话" data-testid="agent-history" @click="openHistory">🕘</button>
  </header>

  <div v-if="banner" class="agent-banner" role="alert" data-testid="agent-banner">
    <span class="grow">{{ banner.message }}</span>
    <button v-if="banner.action" class="btn" @click="bannerAction">{{ banner.action === 'settings' ? '去设置' : '重试' }}</button>
  </div>
  <div v-else-if="ready && isCreate && status && !status.verified" class="agent-note">后台没有配置复核模型，出的题不会经过独立复核</div>

  <main class="page agent">
    <p v-if="opening" class="muted center" data-testid="agent-opening">正在打开对话…</p>
    <div v-else-if="openError" class="card col" data-testid="agent-open-error">
      <span class="err">{{ openError }}</span>
      <div class="row gap"><button class="btn" @click="begin">重试</button><button class="btn" @click="openHistory">回到历史</button></div>
    </div>
    <template v-else-if="chat.messages.length === 0">
      <p class="muted">
        {{ isCreate ? '告诉我出几道题、什么题型，我会依据讲义原文出题，出好的题先放在这里，由你决定是否采纳。' : '可以问我讲义里的内容、你的薄弱点，或者让我出题考你。' }}
      </p>
      <div class="row gap wrap">
        <button v-for="p in prompts" :key="p" class="chip pick" :disabled="!ready" @click="send(p)">{{ p }}</button>
      </div>
    </template>

    <template v-for="m in chat.messages" :key="m.id">
      <div v-if="m.role === 'user'" class="bubble user">
        {{ m.text }}
        <div v-if="m.attachments.length" class="file-tags">
          <span v-for="a in m.attachments" :key="a.id" class="file-tag" data-testid="agent-file-tag">📎 {{ a.name }}</span>
        </div>
      </div>
      <div v-else class="bubble bot">
        <div v-for="t in m.tools" :key="t.id" class="tool" :class="t.status">
          <span v-if="t.status === 'running'" class="spin">◌</span>
          <span v-else-if="t.status === 'error'">⚠</span>
          <span v-else>✓</span>
          {{ t.label }}
        </div>
        <Md v-if="m.text" :source="m.text" agent-links @link="openLink" />
        <div v-if="m.streaming && !m.text && !m.tools.some((t) => t.status === 'running')" class="muted"><span class="spin">◌</span> 正在思考…</div>
        <template v-for="id in m.draftIds" :key="id">
          <DraftCard v-if="chat.drafts[id]" :entry="chat.drafts[id]" @accept="chat.accept(id)" @discard="chat.discard(id)" @revise="revise(id)" />
        </template>
        <p v-if="m.error" class="err">{{ m.error }}</p>
        <p v-if="m.note" class="muted small">{{ m.note }}</p>
      </div>
    </template>
  </main>

  <div v-if="lessonSheet" class="scrim" @click.self="lessonSheet = null">
    <div class="reason-sheet lesson-sheet" role="dialog" aria-label="讲义">
      <h2>{{ lessonTitle(lessonSheet) }}</h2>
      <LessonBody :text="lessonSheet.text" />
      <button class="btn block" @click="lessonSheet = null">关闭</button>
    </div>
  </div>

  <div v-if="questionSheet" class="scrim" @click.self="questionSheet = null">
    <div class="reason-sheet lesson-sheet" role="dialog" aria-label="题目">
      <Md :source="questionSheet.stem" />
      <div v-for="(o, i) in questionSheet.options" :key="i" class="draft-opt" :class="{ right: questionSheet.answer.includes(i) }">
        <span class="letter">{{ String.fromCharCode(65 + i) }}.</span>
        <span class="grow">{{ o }}</span>
        <span v-if="questionSheet.answer.includes(i)">✔</span>
      </div>
      <template v-if="questionSheet.explanation">
        <strong class="small">解析</strong>
        <Md :source="questionSheet.explanation" />
      </template>
      <button class="btn block" @click="questionSheet = null">关闭</button>
    </div>
  </div>

  <footer class="actionbar agent-input">
    <div v-if="chat.files.length" class="agent-files" data-testid="agent-files">
      <div v-for="f in chat.files" :key="f.key" class="file-row" :class="f.status" data-testid="agent-file">
        <div class="file-info">
          <div class="name">📎 {{ f.name }}</div>
          <div v-if="f.status === 'uploading'" class="muted small"><span class="spin">◌</span> 上传中</div>
          <div v-else-if="f.status === 'error'" class="err small">{{ f.error }}</div>
          <div v-else class="muted small">{{ kb(f.size) }}</div>
        </div>
        <button class="icon-btn small" aria-label="移除文件" data-testid="agent-file-remove" @click="chat.removeFile(f.key)">✕</button>
      </div>
    </div>
    <input ref="fileEl" type="file" class="hidden-file" multiple :accept="accept" data-testid="agent-file-input" @change="onFiles" />
    <button
      class="icon-btn attach"
      aria-label="添加文件"
      data-testid="agent-attach"
      :disabled="!ready || !chat.canAttach"
      :title="chat.canAttach ? '添加 .md / .txt 等文本文件' : '文件数量到上限了'"
      @click="pickFile"
    >
      ＋
    </button>
    <textarea
      ref="inputEl"
      v-model="input"
      class="input"
      rows="1"
      data-testid="agent-input"
      :placeholder="ready ? (isCreate ? '说说想出什么题' : '问点什么') : hasToken ? '连接助手后才能提问' : '先填写访问令牌'"
      @keydown.enter="onEnter"
    />
    <button v-if="chat.busy" class="btn" data-testid="agent-stop" aria-label="停止" @click="chat.stop()">■</button>
    <button v-else class="btn primary" data-testid="agent-send" aria-label="发送" :disabled="!canSend" @click="send()">↑</button>
  </footer>
</template>
