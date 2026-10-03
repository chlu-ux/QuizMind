<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import { dataVersion, formatTime, getRepo, showToast } from '@/core/app'
import type { Bank, ExamRecord } from '@/data/types'
import { drawExam, examCountChoices, PASS_PERCENT } from '@/quiz/exam'
import { startExam } from '@/quiz/examLaunch'

const props = defineProps<{ id: string }>()
const router = useRouter()
const bank = ref<Bank | null>(null)
const available = ref(0)
const history = ref<ExamRecord[]>([])
const loaded = ref(false)

/** Seconds per question; null = no time limit. */
const PACES: { label: string; value: number | null }[] = [
  { label: '每题 30 秒', value: 30 },
  { label: '每题 1 分钟', value: 60 },
  { label: '每题 2 分钟', value: 120 },
  { label: '不限时', value: null },
]
const count = ref(0)
const pace = ref<number | null>(60)

async function load() {
  const repo = await getRepo()
  bank.value = (await repo.banks()).find((b) => b.id === props.id) ?? null
  available.value = (await repo.bankQuestions(props.id)).length
  history.value = (await repo.exams(props.id)).slice(0, 10)
  if (!examCountChoices(available.value).includes(count.value)) {
    const choices = examCountChoices(available.value)
    count.value = choices.includes(20) ? 20 : choices[0]
  }
  loaded.value = true
}
onMounted(load)
watch([dataVersion, () => props.id], load)

const choices = computed(() => (available.value ? examCountChoices(available.value) : []))
const limitSec = computed(() => (pace.value === null ? null : pace.value * count.value))
const limitText = computed(() => {
  if (limitSec.value === null) return '不限时'
  const m = Math.round(limitSec.value / 60)
  return m >= 1 ? `${m} 分钟` : `${limitSec.value} 秒`
})

async function begin() {
  const repo = await getRepo()
  const questions = drawExam(await repo.bankQuestions(props.id), count.value)
  if (questions.length === 0) return showToast('这个题库还没有题目')
  await startExam({ bankId: props.id, title: bank.value?.title ?? '模拟考试', questions, limitSec: limitSec.value })
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
    <p v-else-if="loaded && available === 0" class="muted center">这个题库还没有题目</p>
    <template v-else-if="bank">
      <section class="card col">
        <h2>题量</h2>
        <div class="chips">
          <button v-for="n in choices" :key="n" class="pick" :class="{ on: count === n }" @click="count = n">
            {{ n === available && choices.length > 1 ? `全部 ${n}` : n }} 题
          </button>
        </div>
        <h2>时间</h2>
        <div class="chips">
          <button v-for="p in PACES" :key="p.label" class="pick" :class="{ on: pace === p.value }" @click="pace = p.value">
            {{ p.label }}
          </button>
        </div>
        <p class="muted small">
          从题库随机抽 {{ count }} 题，限时 {{ limitText }}，不显示答案，交卷后统一评分，{{ PASS_PERCENT }}% 及格。
          没作答的题按答错算，不记入做题记录；作答过的题会记入统计，答错的进入错题本。
        </p>
      </section>
      <button class="btn primary block" @click="begin">开始考试</button>

      <template v-if="history.length">
        <h2 class="left">考试记录</h2>
        <div v-for="e in history" :key="e.id" class="card">
          <div class="grow">
            <div>
              <strong :class="e.passed ? 'ok' : 'err'">{{ e.percent }} 分</strong>
              <span class="muted small"> · {{ e.passed ? '及格' : '未及格' }}</span>
            </div>
            <div class="muted small">
              {{ formatTime(e.finished_at) }} · 答对 {{ e.correct }}/{{ e.total }} · 用时 {{ usedText(e.used_ms) }}
            </div>
          </div>
        </div>
      </template>
    </template>
  </main>
</template>
