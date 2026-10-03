<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { onBeforeRouteLeave, useRouter } from 'vue-router'
import Md from '@/components/Md.vue'
import { bump, getRepo, runSync, showToast } from '@/core/app'
import { ExamSession, PASS_PERCENT, type ExamItem } from '@/quiz/exam'
import { pendingExam } from '@/quiz/examLaunch'
import { startQuiz } from '@/quiz/launch'

const router = useRouter()
const exam = ref<ExamSession | null>(null)
const sheet = ref(false)
const now = ref(Date.now())
let ticker: ReturnType<typeof setInterval> | undefined
// Set once the exam is over or the learner confirmed leaving, so the route guard stays quiet.
let leaveOk = false

onMounted(async () => {
  const launch = pendingExam.value
  if (!launch) return router.replace('/')
  const repo = await getRepo()
  exam.value = reactive(new ExamSession(launch.bankId, launch.title, launch.questions, repo, launch.limitSec)) as ExamSession
  ticker = setInterval(() => (now.value = Date.now()), 500)
  window.addEventListener('keydown', onKey)
})

onBeforeUnmount(() => {
  clearInterval(ticker)
  window.removeEventListener('keydown', onKey)
  void runSync()
})

onBeforeRouteLeave(() => {
  const e = exam.value
  if (leaveOk || !e || e.submitted) return true
  return confirm('退出后本次考试不会保存，确定退出吗？')
})

const s = computed(() => exam.value)
const remaining = computed(() => s.value?.remainingSec(now.value) ?? null)
const clock = computed(() => {
  const r = remaining.value
  if (r === null) return ''
  return `${Math.floor(r / 60)}:${String(r % 60).padStart(2, '0')}`
})

// Time ran out: hand in whatever is there.
watch(remaining, (r) => {
  if (r === 0 && s.value && !s.value.submitted) {
    showToast('时间到，已自动交卷')
    void finish()
  }
})

async function finish() {
  const e = s.value
  if (!e) return
  await e.submit()
  sheet.value = false
  leaveOk = true
  bump()
  window.scrollTo(0, 0)
}

async function handIn() {
  const e = s.value
  if (!e) return
  const blank = e.length - e.answeredCount
  const ask = blank > 0 ? `还有 ${blank} 题没有作答，确定交卷吗？` : '确定交卷吗？'
  if (confirm(ask)) await finish()
}

function quit() {
  router.back()
}

function onKey(ev: KeyboardEvent) {
  const e = s.value
  if (!e || e.submitted || ev.metaKey || ev.ctrlKey || ev.altKey) return
  if (ev.key >= '1' && ev.key <= '4') e.selectAt(Number(ev.key) - 1)
  else if (ev.key === 'ArrowRight' || ev.key === 'j') e.next()
  else if (ev.key === 'ArrowLeft' || ev.key === 'k') e.previous()
  else return
  ev.preventDefault()
}

function jump(i: number) {
  s.value?.go(i)
  sheet.value = false
}

function optionClass(i: number) {
  return s.value!.selected.includes(i) ? 'picked' : ''
}

// ---- result ----
const result = computed(() => s.value?.result ?? null)
const missed = computed(() => result.value?.items.filter((it) => !it.correct) ?? [])
const usedText = computed(() => {
  const sec = Math.round((result.value?.used_ms ?? 0) / 1000)
  return `${Math.floor(sec / 60)} 分 ${String(sec % 60).padStart(2, '0')} 秒`
})

function answerText(it: ExamItem) {
  const q = it.question
  return q.answer.map((i) => `${q.type === 'judge' ? '' : String.fromCharCode(65 + i) + '. '}${q.options[i]}`).join('、')
}
function pickedText(it: ExamItem) {
  const q = it.question
  if (it.selected.length === 0) return '未作答'
  return it.selected.map((i) => `${q.type === 'judge' ? '' : String.fromCharCode(65 + i) + '. '}${q.options[i]}`).join('、')
}

function retryMissed() {
  void startQuiz('重做错题', missed.value.map((it) => it.question), 0, true)
}
</script>

<template>
  <template v-if="s && !s.submitted">
    <header class="topbar">
      <button class="icon-btn" aria-label="退出考试" @click="quit">×</button>
      <h1 class="clamp">模拟考试 · {{ s.index + 1 }}/{{ s.length }}</h1>
      <span v-if="clock" class="timer" :class="{ low: (remaining ?? 99) <= 60 }">⏱ {{ clock }}</span>
      <button class="btn" @click="handIn">交卷</button>
    </header>
    <div class="bar thin"><div class="fill" :style="{ width: (s.answeredCount / s.length) * 100 + '%' }" /></div>

    <main v-if="sheet" class="page">
      <div class="row between">
        <h2>答题卡</h2>
        <span class="muted small">已答 {{ s.answeredCount }} / {{ s.length }}</span>
      </div>
      <div class="sheet">
        <button
          v-for="(_, i) in s.questions"
          :key="i"
          :class="{ done: s.isAnswered(i), here: i === s.index }"
          @click="jump(i)"
        >
          {{ i + 1 }}
        </button>
      </div>
      <button class="btn primary block" @click="handIn">交卷</button>
      <button class="btn block" @click="sheet = false">继续答题</button>
    </main>

    <template v-else>
      <main class="page quiz">
        <div class="row gap">
          <span class="chip">{{ s.current.type === 'judge' ? '判断题' : '单选题' }}</span>
        </div>
        <Md class="stem" :source="s.current.stem" />
        <button
          v-for="opt in s.displayOptions"
          :key="opt.original"
          class="option"
          :class="optionClass(opt.original)"
          @click="s.select(opt.original)"
        >
          <span class="letter">{{ s.labelOf(opt.original) }}</span>
          <span class="grow">{{ opt.text }}</span>
        </button>
      </main>
      <footer class="actionbar">
        <button class="btn" :disabled="s.index === 0" @click="s.previous()">上一题</button>
        <button class="btn" @click="sheet = true">答题卡</button>
        <button v-if="s.index < s.length - 1" class="btn primary grow" @click="s.next()">下一题</button>
        <button v-else class="btn primary grow" @click="handIn">交卷</button>
      </footer>
    </template>
  </template>

  <template v-else-if="s && result">
    <header class="topbar">
      <button class="icon-btn" aria-label="返回" @click="router.back()">‹</button>
      <h1>考试结果</h1>
    </header>
    <main class="page center">
      <div class="score" :class="result.passed ? 'ok' : 'err'">{{ result.percent }}</div>
      <p>
        <strong :class="result.passed ? 'ok' : 'err'">{{ result.passed ? '及格' : '未及格' }}</strong>
        <span class="muted">（{{ PASS_PERCENT }} 分及格）</span>
      </p>
      <div class="card col">
        <div class="row between"><span class="muted">答对</span><span>{{ result.correct }} / {{ result.total }} 题</span></div>
        <div class="row between"><span class="muted">未作答</span><span>{{ result.total - result.answered }} 题</span></div>
        <div class="row between">
          <span class="muted">用时</span>
          <span>{{ usedText }}<template v-if="result.limit_sec"> / {{ Math.round(result.limit_sec / 60) || 1 }} 分钟</template></span>
        </div>
      </div>

      <div class="sheet">
        <button v-for="(it, i) in result.items" :key="it.question.id" :class="it.correct ? 'ok' : 'no'" disabled>{{ i + 1 }}</button>
      </div>

      <button v-if="missed.length" class="btn primary block" @click="retryMissed">重做错题（{{ missed.length }}）</button>
      <button class="btn block" @click="router.back()">返回</button>

      <h2 class="left">逐题解析</h2>
      <details v-for="(it, i) in result.items" :key="it.question.id" class="card col review left">
        <summary>
          <span :class="it.correct ? 'ok' : 'err'">{{ it.correct ? '✔' : '✘' }}</span>
          {{ i + 1 }}. <span class="clamp2 inline">{{ it.question.stem }}</span>
        </summary>
        <Md :source="it.question.stem" />
        <div class="small">你的答案：<span :class="it.correct ? 'ok' : 'err'">{{ pickedText(it) }}</span></div>
        <div v-if="!it.correct" class="small">正确答案：<span class="ok">{{ answerText(it) }}</span></div>
        <Md v-if="it.question.explanation" :source="it.question.explanation" />
        <blockquote v-if="it.question.source_quote" class="muted small">原文：{{ it.question.source_quote }}</blockquote>
      </details>
    </main>
  </template>
</template>
