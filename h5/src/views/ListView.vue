<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import SyncButton from '@/components/SyncButton.vue'
import { bump, dataVersion, getRepo } from '@/core/app'
import type { LocalQuestion } from '@/data/types'
import { orderQuestions } from '@/quiz/session'
import { startQuiz } from '@/quiz/launch'

const props = defineProps<{ kind: 'wrong' | 'fav' }>()
const wrong = computed(() => props.kind === 'wrong')
const title = computed(() => (wrong.value ? '错题本' : '收藏'))
const items = ref<LocalQuestion[] | null>(null)

async function load() {
  const repo = await getRepo()
  items.value = wrong.value ? await repo.wrongBook() : await repo.favorites()
}
onMounted(load)
watch([dataVersion, () => props.kind], load)

async function remove(q: LocalQuestion) {
  const repo = await getRepo()
  if (wrong.value) await repo.clearFromWrongBook(q.id)
  else await repo.setFavorite(q.id, false)
  bump()
}
</script>

<template>
  <header class="topbar">
    <h1>{{ title }}</h1>
    <SyncButton />
  </header>
  <main class="page">
    <p v-if="items === null" class="muted center">加载中…</p>
    <div v-else-if="items.length === 0" class="empty">
      <div class="big">{{ wrong ? '🎉' : '⭐' }}</div>
      <p>{{ wrong ? '没有错题，继续保持' : '还没有收藏的题目' }}</p>
    </div>
    <template v-else>
      <div class="row between">
        <span class="muted">共 {{ items.length }} 题</span>
        <button class="btn primary" @click="startQuiz(title, orderQuestions(items, 'random'))">随机练习</button>
      </div>
      <div v-for="(q, i) in items" :key="q.id" class="card">
        <button class="grow plain" @click="startQuiz(title, items, i)">
          <div class="clamp2">{{ q.stem }}</div>
          <div class="muted small">{{ q.type === 'judge' ? '判断题' : '单选题' }}</div>
        </button>
        <button class="icon-btn" :aria-label="wrong ? '移出错题本' : '取消收藏'" @click="remove(q)">
          {{ wrong ? '✓' : '★' }}
        </button>
      </div>
    </template>
  </main>
</template>
