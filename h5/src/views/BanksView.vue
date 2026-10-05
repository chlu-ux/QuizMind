<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import SyncButton from '@/components/SyncButton.vue'
import { dataVersion, getRepo, runSync, syncStatus } from '@/core/app'
import { goals, goalStatus, reminderDue, remainingText } from '@/core/goals'
import type { DayProgress } from '@/data/repo'
import type { Bank } from '@/data/types'

const banks = ref<Bank[] | null>(null)
const progress = ref<DayProgress>({ questions: 0, ms: 0 })
// The reminder shows once the clock passes the set time even if the page just sits open.
const now = ref(new Date())
let loadedDay = now.value.toDateString()

async function load() {
  const repo = await getRepo()
  banks.value = await repo.banks()
  progress.value = await repo.todayProgress(Date.now())
  loadedDay = new Date().toDateString()
}
onMounted(load)
watch(dataVersion, load)

const tick = setInterval(() => {
  now.value = new Date()
  // Left open past midnight: today's numbers start from zero again.
  if (now.value.toDateString() !== loadedDay) void load()
}, 30_000)
onBeforeUnmount(() => clearInterval(tick))

const status = computed(() => goalStatus(goals, progress.value))
const due = computed(() => reminderDue(goals, status.value, now.value))
const width = (done: number, goal: number) => Math.min(100, (done * 100) / goal) + '%'
</script>

<template>
  <header class="topbar">
    <h1>题库</h1>
    <SyncButton />
  </header>
  <main class="page">
    <section v-if="status.hasGoal" class="card col goal-card" :class="{ done: status.achieved, due }" aria-label="今日进度">
      <div class="row between">
        <h2>今日进度</h2>
        <span v-if="status.achieved" class="ok">🎉 今天的目标完成了</span>
        <span v-else-if="due" class="err goal-nudge">⏰ {{ remainingText(status) }}</span>
        <span v-else class="muted small">{{ remainingText(status) }}</span>
      </div>
      <div v-if="goals.questions !== null" class="goal-line">
        <div class="row between small"><span>已做题</span><span>{{ status.questionsDone }} / {{ goals.questions }} 题</span></div>
        <div class="bar"><div class="fill" :class="{ good: status.questionsLeft === 0 }" :style="{ width: width(status.questionsDone, goals.questions) }" /></div>
      </div>
      <div v-if="goals.minutes !== null" class="goal-line">
        <div class="row between small"><span>已学习</span><span>{{ status.minutesDone }} / {{ goals.minutes }} 分钟</span></div>
        <div class="bar"><div class="fill" :class="{ good: status.minutesLeft === 0 }" :style="{ width: width(status.minutesDone, goals.minutes) }" /></div>
      </div>
    </section>

    <p v-if="banks === null" class="muted center">加载中…</p>
    <template v-else-if="banks.length === 0">
      <div class="empty">
        <div class="big">☁️</div>
        <p v-if="syncStatus.isError">{{ syncStatus.message }}</p>
        <p v-else>还没有题库。先在管理后台上传文档并审核发布，再点右上角同步。</p>
        <button class="btn primary" :disabled="syncStatus.running" @click="runSync">立即同步</button>
      </div>
    </template>
    <router-link v-for="b in banks" v-else :key="b.id" :to="`/bank/${b.id}`" class="card link">
      <div class="grow">
        <div class="title">{{ b.title }}</div>
        <div v-if="b.description" class="muted clamp">{{ b.description }}</div>
      </div>
      <div class="count">{{ b.question_count }} 题</div>
    </router-link>
  </main>
</template>
