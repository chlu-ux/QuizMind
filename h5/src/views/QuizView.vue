<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import Md from '@/components/Md.vue'
import { bump, getRepo, runSync, showToast } from '@/core/app'
import { pendingQuiz, startQuiz, type QuizLaunch } from '@/quiz/launch'
import { setSequentialPosition } from '@/quiz/position'
import { QuizSession } from '@/quiz/session'
import { FLAG_REASONS, type FlagReason } from '@/data/types'

const router = useRouter()
const session = ref<QuizSession | null>(null)
const favorite = ref(false)
const menu = ref(false)
const reasonSheet = ref(false)

// Where this quiz is saved so it can be continued (a bank id); undefined for lists not worth resuming.
let scope: string | undefined
// Set for 按顺序刷题: the bank whose reading position follows the learner.
let sequentialScope: string | undefined
// What was last written, so opening a resumed quiz does not count as a change.
let savedKey = ''
const progressKey = (q: { index: number; answeredCount: number; finished: boolean }) =>
  `${q.index}/${q.answeredCount}/${q.finished}`

async function begin(launch: QuizLaunch, startAt: number, resume: QuizLaunch['resume']) {
  const repo = await getRepo()
  const q = reactive(
    new QuizSession(launch.title, launch.questions, repo, startAt, undefined, {
      seed: resume?.seed,
      restored: resume?.restored,
    }),
  ) as QuizSession
  scope = launch.scope
  sequentialScope = launch.sequential ? launch.scope : undefined
  if (sequentialScope) setSequentialPosition(sequentialScope, q.current.id)
  if (scope && !resume) await repo.saveSession(scope, q.snapshot())
  savedKey = progressKey(q)
  session.value = q
}

onMounted(async () => {
  const launch = pendingQuiz.value
  if (!launch) return router.replace('/')
  await begin(launch, launch.startAt, launch.resume)
  window.addEventListener('keydown', onKey)
  document.addEventListener('visibilitychange', onVisibility)
})

/** Hidden pages stop the clock; whatever was read so far is booked in case the app never comes back. */
function onVisibility() {
  const cur = session.value
  if (!cur) return
  if (document.hidden) {
    void cur.flush()
    cur.setVisible(false)
  } else cur.setVisible(true)
}

/** 按顺序刷题 only: throw this round away and go through the bank from the first question again. */
async function restart() {
  menu.value = false
  const launch = pendingQuiz.value
  if (!launch || !launch.sequential) return
  if (!window.confirm('从第 1 题重新开始？这一轮的进度会被清掉。')) return
  await session.value?.flush()
  await begin(launch, 0, undefined)
}

watch(
  () => (session.value ? `${session.value.index}/${session.value.finished}` : ''),
  () => {
    const cur = session.value
    if (!cur || !sequentialScope) return
    setSequentialPosition(sequentialScope, cur.finished ? null : cur.current.id)
  },
)

// Keep the saved progress in step with the quiz; finishing it clears the saved copy.
watch(
  () => (session.value ? progressKey(session.value) : ''),
  async (key) => {
    const cur = session.value
    if (!cur || !scope || key === savedKey) return
    savedKey = key
    const repo = await getRepo()
    if (cur.finished) await repo.clearSession(scope)
    else await repo.saveSession(scope, cur.snapshot())
  },
)

onBeforeUnmount(() => {
  window.removeEventListener('keydown', onKey)
  document.removeEventListener('visibilitychange', onVisibility)
  // Book the reading time of the question on screen, then push what was answered while the learner is probably still online.
  void (async () => {
    await session.value?.flush()
    await runSync()
  })()
})

const s = computed(() => session.value)

async function loadFavorite() {
  if (!s.value || s.value.finished) return
  favorite.value = !!(await (await getRepo()).getState(s.value.current.id))?.favorite
}
watch(() => s.value?.current.id, loadFavorite)

async function toggleFavorite() {
  if (!s.value) return
  favorite.value = !favorite.value
  await (await getRepo()).setFavorite(s.value.current.id, favorite.value)
  bump()
}

async function primary() {
  const cur = s.value
  if (!cur) return
  if (cur.submitted) cur.next()
  else {
    await cur.submit()
    bump()
  }
}

function openFlag() {
  menu.value = false
  reasonSheet.value = true
}

async function flag(reason: FlagReason) {
  const cur = s.value
  reasonSheet.value = false
  if (!cur) return
  await cur.flagCurrent(reason)
  showToast('已反馈，下次同步时提交给服务器')
  if (cur.isLast && cur.answeredCount === 0) router.back()
  else cur.next()
}

function onKey(e: KeyboardEvent) {
  const cur = s.value
  if (!cur || cur.finished || e.metaKey || e.ctrlKey || e.altKey) return
  if (e.key >= '1' && e.key <= '4') cur.selectAt(Number(e.key) - 1)
  else if (e.key === 'Enter') void primary()
  else if (e.key === 'j' || e.key === 'ArrowRight') cur.next()
  else if (e.key === 'k' || e.key === 'ArrowLeft') cur.previous()
  else return
  e.preventDefault()
}

const answerText = computed(() => {
  const cur = s.value
  if (!cur) return ''
  const q = cur.current
  return q.answer.map((i) => (q.type === 'judge' ? q.options[i] : cur.labelOf(i))).join('、')
})
const pct = computed(() => (s.value && s.value.answeredCount ? Math.round((s.value.correctCount * 100) / s.value.answeredCount) : 0))

function optionClass(i: number) {
  const cur = s.value!
  const picked = cur.selected.includes(i)
  if (cur.submitted) {
    if (cur.current.answer.includes(i)) return 'right'
    if (picked) return 'wrong'
    return ''
  }
  return picked ? 'picked' : ''
}

function retry() {
  const cur = s.value
  if (cur) void startQuiz('重做错题', cur.missed, 0, true)
}
</script>

<template>
  <template v-if="s && !s.finished">
    <header class="topbar">
      <button class="icon-btn" aria-label="退出" @click="router.back()">×</button>
      <h1 class="clamp">{{ s.title }} · {{ s.index + 1 }}/{{ s.length }}</h1>
      <button class="icon-btn" :aria-label="favorite ? '取消收藏' : '收藏'" @click="toggleFavorite">{{ favorite ? '★' : '☆' }}</button>
      <div class="menu-wrap">
        <button class="icon-btn" aria-label="更多" @click="menu = !menu">⋯</button>
        <div v-if="menu" class="menu">
          <div @click="openFlag">题目有误，反馈</div>
          <div v-if="pendingQuiz?.sequential" @click="restart">从第 1 题重做</div>
        </div>
      </div>
    </header>
    <div class="bar thin"><div class="fill" :style="{ width: ((s.index + (s.submitted ? 1 : 0)) / s.length) * 100 + '%' }" /></div>

    <main class="page quiz">
      <div class="row gap">
        <span class="chip">{{ s.current.type === 'judge' ? '判断题' : '单选题' }}</span>
        <span class="muted small">难度 {{ '★'.repeat(s.current.difficulty) }}</span>
      </div>
      <Md class="stem" :source="s.current.stem" />

      <button
        v-for="opt in s.displayOptions"
        :key="opt.original"
        class="option"
        :class="optionClass(opt.original)"
        :disabled="s.submitted"
        @click="s.select(opt.original)"
      >
        <span class="letter">{{ s.labelOf(opt.original) }}</span>
        <span class="grow">{{ opt.text }}</span>
        <span v-if="s.submitted && s.current.answer.includes(opt.original)">✔</span>
        <span v-else-if="s.submitted && s.selected.includes(opt.original)">✘</span>
      </button>

      <section v-if="s.outcome" class="result" :class="s.outcome.correct ? 'ok-bg' : 'err-bg'">
        <strong>{{ s.outcome.correct ? '回答正确' : `回答错误，正确答案：${answerText}` }}</strong>
        <div v-if="s.outcome.enteredWrongBook" class="small">已加入错题本</div>
        <Md v-if="s.current.explanation" :source="s.current.explanation" />
        <blockquote v-if="s.current.source_quote">原文：{{ s.current.source_quote }}</blockquote>
      </section>
    </main>

    <div v-if="reasonSheet" class="scrim" @click.self="reasonSheet = false">
      <div class="reason-sheet" role="dialog" aria-label="反馈原因">
        <h2>这道题哪里有问题？</h2>
        <button v-for="r in FLAG_REASONS" :key="r.value" class="btn block" @click="flag(r.value)">{{ r.label }}</button>
        <button class="btn block muted" @click="reasonSheet = false">取消</button>
      </div>
    </div>

    <footer class="actionbar">
      <button class="btn" :disabled="!s.canGoBack" @click="s.previous()">上一题</button>
      <button class="btn primary grow" :disabled="s.busy || (!s.submitted && s.selected.length === 0)" @click="primary">
        {{ s.submitted ? (s.isLast ? '完成' : '下一题') : '提交' }}
      </button>
    </footer>
  </template>

  <template v-else-if="s">
    <header class="topbar"><h1>{{ s.title }} · 完成</h1></header>
    <main class="page center">
      <div class="score">{{ pct }}%</div>
      <p>答对 {{ s.correctCount }} / {{ s.answeredCount }} 题</p>
      <template v-if="s.missed.length">
        <h2 class="left">本次错题</h2>
        <div v-for="q in s.missed" :key="q.id" class="card"><span class="err">✘</span><span class="grow clamp2">{{ q.stem }}</span></div>
        <button class="btn primary block" @click="retry">重做错题（{{ s.missed.length }}）</button>
      </template>
      <button class="btn block" @click="router.back()">返回</button>
    </main>
  </template>
</template>
