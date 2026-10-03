<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import ExamResultPanel from '@/components/ExamResultPanel.vue'
import { getRepo } from '@/core/app'
import type { ExamRecord } from '@/data/types'
import { examEntries, type ExamEntry } from '@/quiz/exam'

const props = defineProps<{ id: string }>()
const router = useRouter()
const record = ref<ExamRecord | null>(null)
const entries = ref<ExamEntry[]>([])
const loaded = ref(false)

onMounted(async () => {
  const repo = await getRepo()
  record.value = await repo.exam(props.id)
  if (record.value) {
    const qs = await repo.questionsByIds(record.value.items.map((it) => it.q))
    entries.value = examEntries(record.value, new Map(qs.map((q) => [q.id, q])))
  }
  loaded.value = true
})
</script>

<template>
  <header class="topbar">
    <button class="icon-btn" aria-label="返回" @click="router.back()">‹</button>
    <h1>考试回顾</h1>
  </header>
  <main class="page center">
    <p v-if="loaded && !record" class="muted">没有找到这场考试，可能还没同步到这台设备</p>
    <ExamResultPanel v-else-if="record" :record="record" :entries="entries">
      <template #actions>
        <button class="btn block" @click="router.back()">返回</button>
      </template>
    </ExamResultPanel>
  </main>
</template>
