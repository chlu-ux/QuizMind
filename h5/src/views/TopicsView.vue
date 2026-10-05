<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import { dataVersion, getRepo, showToast } from '@/core/app'
import type { Bank, LocalAttempt, LocalQuestion } from '@/data/types'
import { startQuiz } from '@/quiz/launch'
import { orderQuestions } from '@/quiz/session'
import { applyTopicFilter, topicAvailable, topicQuestions, topicSummary, type TopicFilter } from '@/quiz/topics'

const props = defineProps<{ id: string }>()
const router = useRouter()
const bank = ref<Bank | null>(null)
const questions = ref<LocalQuestion[]>([])
const attempts = ref<LocalAttempt[]>([])
const loaded = ref(false)
// Related tags merged ("UML 辨析" into "UML"), as on the stats page and the exam setup.
const merged = ref(true)
// Which questions of a topic to draw; the two switches exclude each other.
const filter = ref<TopicFilter>('all')

async function load() {
  const repo = await getRepo()
  bank.value = (await repo.banks()).find((b) => b.id === props.id) ?? null
  questions.value = await repo.bankQuestions(props.id)
  attempts.value = await repo.bankAttempts(props.id)
  loaded.value = true
}
onMounted(load)
watch([dataVersion, () => props.id], load)

const topics = computed(() => topicSummary(questions.value, attempts.value, merged.value))

function toggle(f: Exclude<TopicFilter, 'all'>) {
  filter.value = filter.value === f ? 'all' : f
}

const EMPTY: Record<TopicFilter, string> = {
  all: '这个知识点还没有题目',
  new: '这个知识点的题都做过了',
  missed: '这个知识点还没有做错过的题',
}

function start(label: string) {
  const pool = applyTopicFilter(topicQuestions(questions.value, label, merged.value), attempts.value, filter.value)
  if (pool.length === 0) return showToast(EMPTY[filter.value])
  void startQuiz(`知识点 · ${label}`, orderQuestions(pool, 'random'))
}
</script>

<template>
  <header class="topbar">
    <button class="icon-btn" aria-label="返回" @click="router.back()">‹</button>
    <h1 class="clamp">按知识点刷题{{ bank ? ' · ' + bank.title : '' }}</h1>
  </header>
  <main class="page">
    <p v-if="loaded && !bank" class="muted center">题库不存在，可能已被删除</p>
    <p v-else-if="loaded && topics.length === 0" class="muted center">这个题库的题目还没有知识点标签</p>
    <template v-else-if="bank">
      <div class="row between">
        <span class="muted small">点一个知识点，随机刷它下面的题</span>
        <div class="seg-toggle" role="group" aria-label="知识点归类">
          <button :class="{ on: merged }" @click="merged = true">归类</button>
          <button :class="{ on: !merged }" @click="merged = false">细分</button>
        </div>
      </div>
      <div class="chips" role="group" aria-label="刷题范围">
        <button class="pick" :class="{ on: filter === 'new' }" :aria-pressed="filter === 'new'" @click="toggle('new')">只刷没做过的</button>
        <button class="pick" :class="{ on: filter === 'missed' }" :aria-pressed="filter === 'missed'" @click="toggle('missed')">只刷做错过的</button>
      </div>
      <button
        v-for="t in topics"
        :key="t.label"
        class="card plain-card topic"
        :class="{ off: topicAvailable(t, filter) === 0 }"
        @click="start(t.label)"
      >
        <span class="grow">
          <span class="title clamp">{{ t.label }}</span>
          <span class="muted small">
            {{ t.count }} 题<template v-if="filter !== 'all'"> · 可刷 {{ topicAvailable(t, filter) }}</template> · 做过 {{ t.answered }}
          </span>
        </span>
        <span v-if="t.accuracy === null" class="muted small nowrap">未做</span>
        <span v-else class="small nowrap" :class="t.accuracy >= 80 ? 'good' : t.accuracy >= 60 ? 'mid' : 'bad'">{{ t.accuracy }}%</span>
      </button>
    </template>
  </main>
</template>
