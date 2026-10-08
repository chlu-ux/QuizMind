<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { agentApi, agentSettings } from '@/core/agent'
import { formatTime, getRepo } from '@/core/app'
import { AgentError, type AgentConversationItem } from '@/data/agentTypes'

const router = useRouter()
const items = ref<AgentConversationItem[]>([])
const hasMore = ref(false)
const loading = ref(false)
const error = ref('')
const loaded = ref(false)
const bankTitles = ref(new Map<string, string>())
const hasToken = computed(() => agentSettings.token.length > 0)

async function load(more = false) {
  if (loading.value || !hasToken.value) return
  loading.value = true
  error.value = ''
  try {
    const before = more ? items.value[items.value.length - 1]?.updatedAt : undefined
    const page = await agentApi().conversations({ before, limit: 30 })
    items.value = more ? [...items.value, ...page.items] : page.items
    hasMore.value = page.hasMore
    loaded.value = true
  } catch (e) {
    error.value = e instanceof AgentError ? e.message : String(e)
  } finally {
    loading.value = false
  }
}

onMounted(async () => {
  bankTitles.value = new Map((await (await getRepo()).banks()).map((b) => [b.id, b.title]))
  await load()
})

const open = (c: AgentConversationItem) => router.push({ path: '/agent', query: { conversation: c.id } })

async function remove(c: AgentConversationItem) {
  const pending = c.pendingDrafts > 0 ? `\n还有 ${c.pendingDrafts} 道没处理的草稿也会被丢弃。` : ''
  if (!window.confirm(`删除这场对话？${pending}`)) return
  try {
    await agentApi().deleteConversation(c.id)
    items.value = items.value.filter((x) => x.id !== c.id)
  } catch (e) {
    error.value = e instanceof AgentError ? e.message : String(e)
  }
}

const modeLabel = (c: AgentConversationItem) => (c.mode === 'create' ? '出题' : '问 AI')
</script>

<template>
  <header class="topbar">
    <button class="icon-btn" aria-label="返回" @click="router.back()">‹</button>
    <h1>历史对话</h1>
  </header>
  <main class="page">
    <p v-if="!hasToken" class="muted center" data-testid="history-no-token">还没有填访问令牌。到「设置」填写后台设置的访问令牌。</p>
    <div v-else-if="error" class="card col" data-testid="history-error">
      <span class="err">{{ error }}</span>
      <button class="btn" @click="load()">重试</button>
    </div>
    <p v-else-if="loaded && !items.length" class="muted center" data-testid="history-empty">还没有对话</p>
    <div v-for="c in items" :key="c.id" class="card history-row" data-testid="history-row">
      <button class="plain grow" @click="open(c)">
        <span class="title clamp">{{ c.title || '（没有标题）' }}</span>
        <span class="muted small history-meta">
          <span class="chip">{{ modeLabel(c) }}</span>
          <span v-if="bankTitles.get(c.bankId)" class="clamp">{{ bankTitles.get(c.bankId) }}</span>
          <span>{{ formatTime(c.updatedAt) }}</span>
          <span v-if="c.pendingDrafts" class="pending">{{ c.pendingDrafts }} 道草稿待处理</span>
        </span>
      </button>
      <button class="icon-btn" aria-label="删除对话" @click="remove(c)">🗑</button>
    </div>
    <button v-if="hasMore" class="btn" :disabled="loading" data-testid="history-more" @click="load(true)">{{ loading ? '加载中…' : '加载更多' }}</button>
  </main>
</template>
