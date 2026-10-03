<script setup lang="ts">
import { computed } from 'vue'
import Md from '@/components/Md.vue'
import type { ExamRecord } from '@/data/types'
import { PASS_PERCENT, type ExamEntry } from '@/quiz/exam'
import { startQuiz } from '@/quiz/launch'

const props = defineProps<{ record: ExamRecord; entries: ExamEntry[] }>()

const missed = computed(() => props.entries.filter((e) => !e.correct && e.question))
const usedText = computed(() => {
  const sec = Math.round(props.record.used_ms / 1000)
  return `${Math.floor(sec / 60)} 分 ${String(sec % 60).padStart(2, '0')} 秒`
})

function show(q: NonNullable<ExamEntry['question']>, picks: number[]) {
  return picks.map((i) => `${q.type === 'judge' ? '' : String.fromCharCode(65 + i) + '. '}${q.options[i]}`).join('、')
}
const pickedText = (e: ExamEntry) => (e.selected.length === 0 ? '未作答' : e.question ? show(e.question, e.selected) : '')

function retryMissed() {
  void startQuiz('重做错题', missed.value.map((e) => e.question!), 0, true)
}
</script>

<template>
  <div class="score" :class="record.passed ? 'ok' : 'err'">{{ record.percent }}</div>
  <p>
    <strong :class="record.passed ? 'ok' : 'err'">{{ record.passed ? '及格' : '未及格' }}</strong>
    <span class="muted">（{{ PASS_PERCENT }} 分及格）</span>
  </p>
  <div class="card col">
    <div class="row between"><span class="muted">答对</span><span>{{ record.correct }} / {{ record.total }} 题</span></div>
    <div class="row between"><span class="muted">未作答</span><span>{{ record.total - record.answered }} 题</span></div>
    <div class="row between">
      <span class="muted">用时</span>
      <span>{{ usedText }}<template v-if="record.limit_sec"> / {{ Math.round(record.limit_sec / 60) || 1 }} 分钟</template></span>
    </div>
  </div>

  <div v-if="entries.length" class="sheet">
    <button v-for="(e, i) in entries" :key="e.id" :class="e.correct ? 'ok' : 'no'" disabled>{{ i + 1 }}</button>
  </div>
  <p v-else class="muted small">这场考试是旧版本记录的，只保留了成绩，没有逐题明细。</p>

  <button v-if="missed.length" class="btn primary block" @click="retryMissed">重做错题（{{ missed.length }}）</button>
  <slot name="actions" />

  <template v-if="entries.length">
    <h2 class="left">逐题解析</h2>
    <details v-for="(e, i) in entries" :key="e.id" class="card col review left">
      <summary>
        <span :class="e.correct ? 'ok' : 'err'">{{ e.correct ? '✔' : '✘' }}</span>
        {{ i + 1 }}. <span class="clamp2 inline">{{ e.question ? e.question.stem : '（这道题已下线）' }}</span>
      </summary>
      <template v-if="e.question">
        <Md :source="e.question.stem" />
        <div class="small">你的答案：<span :class="e.correct ? 'ok' : 'err'">{{ pickedText(e) }}</span></div>
        <div v-if="!e.correct" class="small">正确答案：<span class="ok">{{ show(e.question, e.question.answer) }}</span></div>
        <Md v-if="e.question.explanation" :source="e.question.explanation" />
        <blockquote v-if="e.question.source_quote" class="muted small">原文：{{ e.question.source_quote }}</blockquote>
      </template>
      <p v-else class="muted small">题目已被下线，看不到内容；当时你{{ e.selected.length ? '作了答' : '没有作答' }}，{{ e.correct ? '答对了' : '没答对' }}。</p>
    </details>
  </template>
</template>
