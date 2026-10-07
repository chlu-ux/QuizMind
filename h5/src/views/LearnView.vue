<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import { dataVersion, getRepo } from '@/core/app'
import type { Bank, Lesson } from '@/data/types'
import { groupChapters, lessonProgress, lessonTitle, nextToStudy, STATE_LABEL, type LessonProgress } from '@/quiz/lessons'

const props = defineProps<{ id: string }>()
const router = useRouter()
const bank = ref<Bank | null>(null)
const lessons = ref<Lesson[]>([])
const progress = ref(new Map<string, LessonProgress>())
const loaded = ref(false)
// Chapters the reader opened or closed by hand; the rest are closed, except the one holding the next section to study.
const forced = ref(new Map<string, boolean>())

async function load() {
  const repo = await getRepo()
  bank.value = (await repo.banks()).find((b) => b.id === props.id) ?? null
  lessons.value = await repo.lessons(props.id)
  progress.value = lessonProgress(
    lessons.value,
    await repo.bankQuestions(props.id),
    await repo.bankAttempts(props.id),
    await repo.lessonReadIds(props.id),
  )
  loaded.value = true
}
onMounted(load)
watch([dataVersion, () => props.id], load)

const chapters = computed(() => groupChapters(lessons.value))
const next = computed(() => nextToStudy(lessons.value, progress.value))
const count = (state: string) => lessons.value.filter((l) => progress.value.get(l.id)?.state === state).length
const readCount = computed(() => lessons.value.filter((l) => progress.value.get(l.id)?.read).length)
const mastered = computed(() => count('mastered'))
const percent = computed(() => (lessons.value.length ? (readCount.value / lessons.value.length) * 100 : 0))

function chapterRead(ls: Lesson[]) {
  return ls.filter((l) => progress.value.get(l.id)?.read).length
}
function chapterMastered(ls: Lesson[]) {
  return ls.filter((l) => progress.value.get(l.id)?.state === 'mastered').length
}
const isOpen = (id: string, ls: Lesson[]) =>
  forced.value.get(id) ?? (next.value !== null && ls.some((l) => l.id === next.value!.id))
function toggle(id: string, ls: Lesson[]) {
  forced.value = new Map(forced.value).set(id, !isOpen(id, ls))
}

const go = (l: Lesson) => router.push(`/bank/${props.id}/learn/${l.id}`)
</script>

<template>
  <header class="topbar">
    <button class="icon-btn" aria-label="返回" @click="router.back()">‹</button>
    <h1 class="clamp">学习{{ bank ? ' · ' + bank.title : '' }}</h1>
  </header>
  <main class="page">
    <p v-if="loaded && !bank" class="muted center">题库不存在，可能已被删除</p>
    <p v-else-if="loaded && lessons.length === 0" class="muted center">这个题库还没有讲义。同步一次试试，或在管理后台上传文档。</p>
    <template v-else-if="bank">
      <div class="card col">
        <div>已读 {{ readCount }} / {{ lessons.length }} 节 · 已掌握 {{ mastered }} 节</div>
        <div class="bar"><div class="fill" :style="{ width: percent + '%' }" /></div>
        <span class="muted small">先读讲义，再做这一节的题；做过至少 5 题（不足 5 题则全部做完）且最近一次正确率达到 80%，算「已掌握」</span>
      </div>
      <button v-if="next" class="btn primary block" @click="go(next)">
        ▶ {{ progress.get(next.id)?.read ? '继续巩固' : readCount === 0 ? '开始学习' : '继续学习' }} · {{ lessonTitle(next) }}
      </button>
      <p v-else class="muted center">所有小节都已读完并掌握 🎉</p>

      <section v-for="c in chapters" :key="c.id" class="stack">
        <button class="chapter-head" :class="{ open: isOpen(c.id, c.lessons) }" :aria-expanded="isOpen(c.id, c.lessons)" @click="toggle(c.id, c.lessons)">
          <span class="arrow">›</span>
          <span class="grow clamp">{{ c.title }}</span>
          <span class="muted small nowrap">{{ chapterRead(c.lessons) }}/{{ c.lessons.length }} · 掌握 {{ chapterMastered(c.lessons) }}</span>
        </button>
        <template v-if="isOpen(c.id, c.lessons)">
          <button v-for="l in c.lessons" :key="l.id" class="card plain-card lesson-row" @click="go(l)">
            <span class="grow">
              <span class="title clamp2">{{ lessonTitle(l) }}</span>
              <span class="muted small">
                <template v-if="progress.get(l.id)?.total">
                  {{ progress.get(l.id)!.total }} 题 · 做过 {{ progress.get(l.id)!.answered }}<template v-if="progress.get(l.id)!.accuracy !== null"> · 正确率 {{ progress.get(l.id)!.accuracy }}%</template>
                </template>
                <template v-else>没有配套的题</template>
              </span>
            </span>
            <span class="state" :class="progress.get(l.id)?.state">{{ STATE_LABEL[progress.get(l.id)?.state ?? 'new'] }}</span>
          </button>
        </template>
      </section>
    </template>
  </main>
</template>
