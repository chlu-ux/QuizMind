<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import { dataVersion, formatTime, getRepo, showToast } from '@/core/app'
import type { Bank, ExamDraft, ExamRecord, LocalQuestion } from '@/data/types'
import { drawPaper, examCountChoices, paperPool, paperTags, PASS_PERCENT, STRATEGIES, type PaperStrategy } from '@/quiz/exam'
import { startExam } from '@/quiz/examLaunch'

const props = defineProps<{ id: string }>()
const router = useRouter()
const bank = ref<Bank | null>(null)
const questions = ref<LocalQuestion[]>([])
const history = ref<ExamRecord[]>([])
const draft = ref<ExamDraft | null>(null)
const loaded = ref(false)
const now = ref(Date.now())

/** Seconds per question; null = no time limit. */
const PACES: { label: string; value: number | null }[] = [
  { label: '每题 30 秒', value: 30 },
  { label: '每题 1 分钟', value: 60 },
  { label: '每题 2 分钟', value: 120 },
  { label: '不限时', value: null },
]
const count = ref(0)
const pace = ref<number | null>(60)
const strategy = ref<PaperStrategy>('random')
const topics = ref<string[]>([])

async function load() {
  const repo = await getRepo()
  bank.value = (await repo.banks()).find((b) => b.id === props.id) ?? null
  questions.value = await repo.bankQuestions(props.id)
  history.value = (await repo.exams(props.id)).slice(0, 10)
  draft.value = (await repo.examDraft(props.id)) ?? null
  now.value = Date.now()
  loaded.value = true
}
onMounted(load)
watch([dataVersion, () => props.id], load)

const allTopics = computed(() => paperTags(questions.value))
const pool = computed(() => paperPool(questions.value, topics.value))
const choices = computed(() => (pool.value.length ? examCountChoices(pool.value.length) : []))
// Keep the chosen count valid as the pool changes (e.g. after picking topics).
watch(choices, (list) => {
  if (list.length && !list.includes(count.value)) count.value = list.includes(20) ? 20 : list[0]
}, { immediate: true })

const limitSec = computed(() => (pace.value === null ? null : pace.value * count.value))
const limitText = computed(() => {
  if (limitSec.value === null) return '不限时'
  const m = Math.round(limitSec.value / 60)
  return m >= 1 ? `${m} 分钟` : `${limitSec.value} 秒`
})
const strategyHint = computed(() => STRATEGIES.find((s) => s.value === strategy.value)?.hint ?? '')

function toggleTopic(label: string) {
  topics.value = topics.value.includes(label) ? topics.value.filter((t) => t !== label) : [...topics.value, label]
}

async function begin() {
  const repo = await getRepo()
  const all = await repo.bankQuestions(props.id)
  const history = await repo.practiceHistory(new Set(all.map((q) => q.id)))
  const wrongIds = new Set((await repo.wrongBook()).map((q) => q.id))
  const picked = drawPaper(all, count.value, { strategy: strategy.value, tags: topics.value, history, wrongIds })
  if (picked.length === 0) return showToast('没有符合条件的题目')
  await startExam({ bankId: props.id, title: bank.value?.title ?? '模拟考试', questions: picked, limitSec: limitSec.value })
}

// ---- unfinished exam ----
const draftLeft = computed(() => {
  const d = draft.value
  if (!d || d.limit_sec === null) return null
  return Math.max(0, Math.ceil(d.limit_sec - (now.value - d.started_at) / 1000))
})
const draftLeftText = computed(() => {
  const r = draftLeft.value
  if (r === null) return '不限时'
  if (r === 0) return '时间已到，继续将直接交卷'
  return `剩余 ${Math.floor(r / 60)}:${String(r % 60).padStart(2, '0')}`
})

async function resume() {
  const d = draft.value
  if (!d) return
  const repo = await getRepo()
  const qs = await repo.questionsByIds(d.ids)
  if (qs.length === 0) {
    await repo.clearExamDraft(props.id)
    draft.value = null
    return showToast('这场考试的题目都已下线，无法继续')
  }
  await startExam({ bankId: d.bank_id, title: d.title, questions: qs, limitSec: d.limit_sec, draft: d })
}

async function discard() {
  if (!confirm('放弃这场没做完的考试？已作的答案不会保存，也不计入统计。')) return
  await (await getRepo()).clearExamDraft(props.id)
  draft.value = null
}

const usedText = (ms: number) => {
  const s = Math.round(ms / 1000)
  return `${Math.floor(s / 60)}分${String(s % 60).padStart(2, '0')}秒`
}
</script>

<template>
  <header class="topbar">
    <button class="icon-btn" aria-label="返回" @click="router.back()">‹</button>
    <h1 class="clamp">{{ bank?.title ?? '题库' }} · 模拟考试</h1>
  </header>
  <main class="page">
    <p v-if="loaded && !bank" class="muted center">题库不存在，可能已被删除</p>
    <p v-else-if="loaded && questions.length === 0" class="muted center">这个题库还没有题目</p>
    <template v-else-if="bank">
      <section v-if="draft" class="card col resume">
        <div>
          <strong>有一场没做完的考试</strong>
          <div class="muted small">
            已答 {{ Object.keys(draft.answers).length }} / {{ draft.ids.length }} 题 · {{ draftLeftText }}
          </div>
        </div>
        <div class="row gap">
          <button class="btn primary grow" @click="resume">继续考试</button>
          <button class="btn" @click="discard">放弃</button>
        </div>
      </section>

      <section class="card col">
        <h2>出卷方式</h2>
        <div class="chips">
          <button v-for="s in STRATEGIES" :key="s.value" class="pick" :class="{ on: strategy === s.value }" @click="strategy = s.value">
            {{ s.label }}
          </button>
        </div>
        <p class="muted small">{{ strategyHint }}</p>

        <template v-if="allTopics.length > 1">
          <div class="row between">
            <h2>知识点</h2>
            <button v-if="topics.length" class="plain small" @click="topics = []">清除（{{ topics.length }}）</button>
          </div>
          <div class="chips topics">
            <button class="pick" :class="{ on: topics.length === 0 }" @click="topics = []">全部</button>
            <button v-for="t in allTopics.slice(0, 40)" :key="t.label" class="pick" :class="{ on: topics.includes(t.label) }" @click="toggleTopic(t.label)">
              {{ t.label }} <small class="muted">{{ t.count }}</small>
            </button>
          </div>
        </template>

        <h2>题量</h2>
        <div class="chips">
          <button v-for="n in choices" :key="n" class="pick" :class="{ on: count === n }" @click="count = n">
            {{ n === pool.length && choices.length > 1 ? `全部 ${n}` : n }} 题
          </button>
        </div>
        <h2>时间</h2>
        <div class="chips">
          <button v-for="p in PACES" :key="p.label" class="pick" :class="{ on: pace === p.value }" @click="pace = p.value">
            {{ p.label }}
          </button>
        </div>
        <p class="muted small">
          共 {{ count }} 题，限时 {{ limitText }}，不显示答案，交卷后统一评分，{{ PASS_PERCENT }}% 及格。
          没作答的题按答错算，不记入做题记录；作答过的题会记入统计，答错的进入错题本。
          考到一半退出，进度会保留，回到这里可以继续。
        </p>
      </section>
      <button class="btn primary block" :disabled="pool.length === 0" @click="begin">
        {{ draft ? '另开一场新考试' : '开始考试' }}
      </button>

      <template v-if="history.length">
        <h2 class="left">考试记录</h2>
        <button v-for="e in history" :key="e.id" class="card link plain-card" @click="router.push(`/exam/review/${e.id}`)">
          <div class="grow">
            <div>
              <strong :class="e.passed ? 'ok' : 'err'">{{ e.percent }} 分</strong>
              <span class="muted small"> · {{ e.passed ? '及格' : '未及格' }}</span>
            </div>
            <div class="muted small">
              {{ formatTime(e.finished_at) }} · 答对 {{ e.correct }}/{{ e.total }} · 用时 {{ usedText(e.used_ms) }}
            </div>
          </div>
          <span class="muted">›</span>
        </button>
      </template>
    </template>
  </main>
</template>
