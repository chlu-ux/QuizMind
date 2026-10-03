<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import { dataVersion, getRepo, showToast } from '@/core/app'
import type { BankStats } from '@/data/repo'
import type { Bank, SessionData } from '@/data/types'
import { orderQuestions, type QuizOrder } from '@/quiz/session'
import { startQuiz } from '@/quiz/launch'
import { planResume } from '@/quiz/resume'

const props = defineProps<{ id: string }>()
const router = useRouter()
const bank = ref<Bank | null>(null)
const stats = ref<BankStats | null>(null)
const saved = ref<SessionData | null>(null)
const loaded = ref(false)

async function load() {
  const repo = await getRepo()
  bank.value = (await repo.banks()).find((b) => b.id === props.id) ?? null
  stats.value = await repo.bankStats(props.id)
  saved.value = await repo.savedSession(props.id)
  loaded.value = true
}
onMounted(load)
watch([dataVersion, () => props.id], load)

const progress = computed(() => (stats.value && stats.value.total ? (stats.value.answered / stats.value.total) * 100 : 0))

async function start(order: QuizOrder, onlyNew: boolean) {
  const repo = await getRepo()
  let qs = await repo.bankQuestions(props.id)
  if (onlyNew) {
    const done = await repo.answeredIds(qs.map((q) => q.id))
    qs = qs.filter((q) => !done.has(q.id))
    if (qs.length === 0) return showToast('这个题库的题都做过了')
  }
  if (qs.length === 0) return showToast('这个题库还没有题目')
  startQuiz(bank.value?.title ?? '刷题', orderQuestions(qs, order), 0, false, { scope: props.id })
}

async function resume() {
  if (!saved.value) return
  const repo = await getRepo()
  const plan = await planResume(saved.value, repo)
  if (!plan) {
    // Every question in it has since been withdrawn.
    await repo.clearSession(props.id)
    saved.value = null
    return showToast('上次的题目已不存在，请重新开始')
  }
  startQuiz(plan.title, plan.questions, plan.index, false, { scope: props.id, resume: plan })
}
</script>

<template>
  <header class="topbar">
    <button class="icon-btn" aria-label="返回" @click="router.back()">‹</button>
    <h1>{{ bank?.title ?? '题库' }}</h1>
  </header>
  <main class="page">
    <p v-if="loaded && !bank" class="muted center">题库不存在，可能已被删除</p>
    <template v-else-if="bank">
      <p v-if="bank.description" class="muted">{{ bank.description }}</p>
      <div v-if="stats" class="card col">
        <div>累计做过 {{ stats.answered }} / {{ stats.total }} 题（不重复）· 最近一次答对 {{ stats.correct }} 题</div>
        <div class="bar"><div class="fill" :style="{ width: progress + '%' }" /></div>
      </div>
      <div class="stack">
        <template v-if="saved">
          <button class="btn primary block" @click="resume">
            ▶ 继续上一轮 · 第 {{ saved.index + 1 }} / {{ saved.ids.length }} 题（本轮已答 {{ Object.keys(saved.answers).length }}）
          </button>
          <button class="btn block" @click="start('random', false)">🔀 重新随机刷题</button>
        </template>
        <button v-else class="btn primary block" @click="start('random', false)">🔀 随机刷题</button>
        <button class="btn block" @click="start('random', true)">🆕 只做没做过的</button>
        <button class="btn block" @click="start('sequential', false)">🔢 按顺序刷题</button>
        <button class="btn block" @click="router.push(`/bank/${props.id}/exam`)">📝 模拟考试</button>
        <button class="btn block" @click="router.push(`/bank/${props.id}/stats`)">📊 统计分析</button>
      </div>
    </template>
  </main>
</template>
