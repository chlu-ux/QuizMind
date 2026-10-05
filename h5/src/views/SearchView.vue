<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import { getRepo } from '@/core/app'
import type { Bank, LocalQuestion } from '@/data/types'
import { startQuiz } from '@/quiz/launch'
import { highlight, searchQuestions, searchTerms } from '@/quiz/search'
import { orderQuestions } from '@/quiz/session'

const props = defineProps<{ id: string }>()
const router = useRouter()

/** Rows drawn at once; a broad word in a big bank would otherwise put thousands of nodes on the page. */
const SHOW = 100
const DEBOUNCE_MS = 200

const bank = ref<Bank | null>(null)
const questions = ref<LocalQuestion[]>([])
const loaded = ref(false)
const text = ref('')
// What is actually searched: the box, a moment after the last key press.
const query = ref('')
let timer: ReturnType<typeof setTimeout> | undefined

onMounted(async () => {
  const repo = await getRepo()
  bank.value = (await repo.banks()).find((b) => b.id === props.id) ?? null
  questions.value = await repo.bankQuestions(props.id)
  loaded.value = true
})
onBeforeUnmount(() => clearTimeout(timer))

watch(text, (v) => {
  clearTimeout(timer)
  timer = setTimeout(() => (query.value = v), DEBOUNCE_MS)
})

const terms = computed(() => searchTerms(query.value))
const hits = computed(() => searchQuestions(questions.value, query.value))
const shown = computed(() => hits.value.slice(0, SHOW))
const results = computed(() => hits.value.map((h) => h.question))
const title = computed(() => `搜索：${query.value.trim()}`)

const WHERE: Record<string, string> = { option: '选项', tag: '知识点', explanation: '解析' }

function start(i: number) {
  void startQuiz(title.value, results.value, i)
}
function practice() {
  void startQuiz(title.value, orderQuestions(results.value, 'random'))
}
</script>

<template>
  <header class="topbar">
    <button class="icon-btn" aria-label="返回" @click="router.back()">‹</button>
    <h1 class="clamp">搜索{{ bank ? ' · ' + bank.title : '' }}</h1>
  </header>
  <main class="page">
    <p v-if="loaded && !bank" class="muted center">题库不存在，可能已被删除</p>
    <template v-else>
      <input
        v-model="text"
        class="input"
        type="search"
        placeholder="搜索题干、选项、解析、知识点"
        aria-label="搜索题目"
        autofocus
      />
      <p v-if="terms.length === 0" class="muted small">
        输入关键词开始搜索。多个词用空格分开，都要出现；不分大小写和全角半角；离线也能用。
      </p>
      <p v-else-if="hits.length === 0" class="muted center">没有找到包含「{{ terms.join(' ') }}」的题目</p>
      <template v-else>
        <div class="row between">
          <span class="muted">找到 {{ hits.length }} 题</span>
          <button class="btn primary" @click="practice">练习这 {{ hits.length }} 道</button>
        </div>
        <div v-for="(h, i) in shown" :key="h.question.id" class="card">
          <button class="grow plain" @click="start(i)">
            <div class="clamp2">
              <template v-for="(p, k) in highlight(h.question.stem, terms)" :key="k">
                <mark v-if="p.hit">{{ p.text }}</mark>
                <template v-else>{{ p.text }}</template>
              </template>
            </div>
            <div v-if="h.snippet" class="snippet small">
              <span class="muted">{{ WHERE[h.where] }}：</span>
              <template v-for="(p, k) in highlight(h.snippet, terms)" :key="k">
                <mark v-if="p.hit">{{ p.text }}</mark>
                <template v-else>{{ p.text }}</template>
              </template>
            </div>
            <div class="muted small">
              {{ h.question.type === 'judge' ? '判断题' : '单选题' }} · 难度 {{ '★'.repeat(h.question.difficulty) }}
              <template v-if="h.question.tags.length"> · {{ h.question.tags.join('、') }}</template>
            </div>
          </button>
        </div>
        <p v-if="hits.length > shown.length" class="muted center small">
          还有 {{ hits.length - shown.length }} 条，请缩小范围
        </p>
      </template>
    </template>
  </main>
</template>
