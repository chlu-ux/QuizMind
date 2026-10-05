<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { onBeforeRouteLeave, useRouter } from 'vue-router'
import ExamResultPanel from '@/components/ExamResultPanel.vue'
import Md from '@/components/Md.vue'
import OptText from '@/components/OptText.vue'
import { bump, getRepo, runSync, showToast } from '@/core/app'
import { ExamSession } from '@/quiz/exam'
import { pendingExam } from '@/quiz/examLaunch'

const router = useRouter()
const exam = ref<ExamSession | null>(null)
const sheet = ref(false)
const now = ref(Date.now())
let ticker: ReturnType<typeof setInterval> | undefined
// Set once the exam is over or the learner confirmed leaving, so the route guard stays quiet.
let leaveOk = false

onMounted(async () => {
  const repo = await getRepo()
  const launch = pendingExam.value
  pendingExam.value = null
  let session: ExamSession | null = null
  if (launch?.draft) {
    session = ExamSession.restore(launch.draft, launch.questions, repo)
  } else if (launch) {
    session = new ExamSession(launch.bankId, launch.title, launch.questions, repo, launch.limitSec)
  } else {
    // A reload, or the app was killed: pick up the exam that was in progress.
    const draft = await repo.latestExamDraft()
    if (draft) {
      session = ExamSession.restore(draft, await repo.questionsByIds(draft.ids), repo)
      if (!session) await repo.clearExamDraft(draft.bank_id)
    }
  }
  if (!session) return router.replace('/')
  exam.value = reactive(session) as ExamSession
  exam.value.save() // so a reload before the first answer still finds it
  ticker = setInterval(() => (now.value = Date.now()), 500)
  window.addEventListener('keydown', onKey)
  if (exam.value.remainingSec() === 0) {
    showToast('考试时间已到，已按现有答案交卷')
    await finish()
  }
})

onBeforeUnmount(() => {
  clearInterval(ticker)
  window.removeEventListener('keydown', onKey)
  void runSync()
})

onBeforeRouteLeave(() => {
  const e = exam.value
  if (leaveOk || !e || e.submitted || e.limitSec === null) return true
  return confirm('退出后进度会保留，可以回到「模拟考试」继续，但限时考试的计时不会暂停。确定退出吗？')
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
  try {
    await e.submit()
  } catch (err) {
    showToast(`交卷失败：${(err as Error).message}，请再试一次`, true)
    return
  }
  sheet.value = false
  leaveOk = true
  bump()
  window.scrollTo(0, 0)
}

async function handIn() {
  const e = s.value
  if (!e) return
  const notes = []
  if (e.length - e.answeredCount > 0) notes.push(`还有 ${e.length - e.answeredCount} 题没有作答`)
  if (e.markedCount > 0) notes.push(`有 ${e.markedCount} 题标记了待检查`)
  const ask = notes.length ? `${notes.join('，')}，确定交卷吗？` : '确定交卷吗？'
  if (confirm(ask)) await finish()
}

async function abandon() {
  const e = s.value
  if (!e || !confirm('放弃这次考试？已作的答案不会保存，也不计入统计。')) return
  exam.value = null // nothing can change (or re-save) the exam from here on
  await (await getRepo()).clearExamDraft(e.bankId)
  leaveOk = true
  router.back()
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
  else if (ev.key === 'm') e.toggleMark()
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
</script>

<template>
  <template v-if="s && !s.submitted">
    <header class="topbar">
      <button class="icon-btn" aria-label="退出考试" @click="quit">×</button>
      <h1 class="clamp">模拟考试 · {{ s.index + 1 }}/{{ s.length }}</h1>
      <span v-if="clock" class="timer" :class="{ low: (remaining ?? 99) <= 60 }">⏱ {{ clock }}</span>
      <button class="btn" :disabled="s.busy" @click="handIn">交卷</button>
    </header>
    <div class="bar thin"><div class="fill" :style="{ width: (s.answeredCount / s.length) * 100 + '%' }" /></div>

    <main v-if="sheet" class="page">
      <div class="row between">
        <h2>答题卡</h2>
        <span class="muted small">已答 {{ s.answeredCount }} / {{ s.length }}<template v-if="s.markedCount"> · 待检查 {{ s.markedCount }}</template></span>
      </div>
      <div class="sheet">
        <button
          v-for="(_, i) in s.questions"
          :key="i"
          :class="{ done: s.isAnswered(i), here: i === s.index, marked: s.isMarked(i) }"
          :aria-label="`第 ${i + 1} 题${s.isMarked(i) ? '，待检查' : ''}${s.isAnswered(i) ? '，已答' : '，未答'}`"
          @click="jump(i)"
        >
          {{ i + 1 }}
        </button>
      </div>
      <div class="legend small muted">
        <i class="dot done" />已答 <i class="dot blank" />未答 <i class="dot flag" />待检查
      </div>
      <button class="btn primary block" :disabled="s.busy" @click="handIn">交卷</button>
      <button class="btn block" @click="sheet = false">继续答题</button>
      <button class="btn block danger" @click="abandon">放弃本次考试</button>
    </main>

    <template v-else>
      <main class="page quiz">
        <div class="row between">
          <span class="chip">{{ s.current.type === 'judge' ? '判断题' : '单选题' }}</span>
          <button class="flag-btn" :class="{ on: s.isMarked(s.index) }" :aria-pressed="s.isMarked(s.index)" @click="s.toggleMark()">
            🚩 {{ s.isMarked(s.index) ? '已标记待检查' : '标记待检查' }}
          </button>
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
          <OptText class="grow" :text="opt.text" />
        </button>
      </main>
      <footer class="actionbar">
        <button class="btn" :disabled="s.index === 0" @click="s.previous()">上一题</button>
        <button class="btn" @click="sheet = true">答题卡</button>
        <button v-if="s.index < s.length - 1" class="btn primary grow" @click="s.next()">下一题</button>
        <button v-else class="btn primary grow" :disabled="s.busy" @click="handIn">交卷</button>
      </footer>
    </template>
  </template>

  <template v-else-if="s && s.result">
    <header class="topbar">
      <button class="icon-btn" aria-label="返回" @click="router.back()">‹</button>
      <h1>考试结果</h1>
    </header>
    <main class="page center">
      <ExamResultPanel :record="s.result" :entries="s.result.entries">
        <template #actions>
          <button class="btn block" @click="router.back()">返回</button>
        </template>
      </ExamResultPanel>
    </main>
  </template>
</template>
