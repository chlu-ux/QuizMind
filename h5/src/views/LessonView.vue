<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import LessonBody from '@/components/LessonBody.vue'
import { dataVersion, getRepo, showToast } from '@/core/app'
import type { Lesson, LocalQuestion } from '@/data/types'
import { startQuiz } from '@/quiz/launch'
import { groupChapters, lessonProgress, lessonQuestions, lessonTitle, STATE_LABEL, type LessonProgress } from '@/quiz/lessons'
import { orderQuestions } from '@/quiz/session'

const props = defineProps<{ id: string; lessonId: string }>()
const router = useRouter()
const lesson = ref<Lesson | null>(null)
const chapterTitle = ref('')
const prev = ref<Lesson | null>(null)
const next = ref<Lesson | null>(null)
const questions = ref<LocalQuestion[]>([])
const progress = ref<LessonProgress | null>(null)
const read = ref(false)
const loaded = ref(false)
// 背诵模式: sentences are blurred until tapped.
const cover = ref(false)

async function load() {
  const repo = await getRepo()
  const all = await repo.lessons(props.id)
  const at = all.findIndex((l) => l.id === props.lessonId)
  lesson.value = at >= 0 ? all[at] : null
  if (lesson.value) {
    // Neighbours within the reading order of the whole bank, so the last section of a chapter leads on to the next chapter.
    prev.value = all[at - 1] ?? null
    next.value = all[at + 1] ?? null
    chapterTitle.value = groupChapters(all).find((c) => c.id === lesson.value!.document_id)?.title ?? ''
    const bankQuestions = await repo.bankQuestions(props.id)
    questions.value = lessonQuestions(lesson.value.id, bankQuestions)
    const reads = await repo.lessonReadIds(props.id)
    read.value = reads.has(lesson.value.id)
    progress.value =
      lessonProgress([lesson.value], questions.value, await repo.bankAttempts(props.id), reads).get(lesson.value.id) ?? null
  }
  loaded.value = true
}
onMounted(load)
watch([dataVersion, () => props.id, () => props.lessonId], load)
// A new section starts at the top, uncovered.
watch(
  () => props.lessonId,
  () => {
    cover.value = false
    window.scrollTo(0, 0)
  },
)

async function setRead(value: boolean) {
  const l = lesson.value
  if (!l) return
  const repo = await getRepo()
  if (value) await repo.markLessonRead(l)
  else await repo.unmarkLessonRead(l.id)
  read.value = value
}

async function practise() {
  const l = lesson.value
  if (!l) return
  if (questions.value.length === 0) return showToast('这一节还没有配套的题')
  await setRead(true)
  void startQuiz(`本节 · ${lessonTitle(l)}`, orderQuestions(questions.value, 'random'))
}

async function go(to: Lesson | null) {
  if (!to) return
  await setRead(true)
  void router.replace(`/bank/${props.id}/learn/${to.id}`)
}

async function done() {
  await setRead(true)
  if (next.value) void router.replace(`/bank/${props.id}/learn/${next.value.id}`)
  else void router.back()
}

const state = computed(() => STATE_LABEL[progress.value?.state ?? 'new'])
</script>

<template>
  <header class="topbar">
    <button class="icon-btn" aria-label="返回" @click="router.back()">‹</button>
    <h1 class="clamp">{{ lesson ? lessonTitle(lesson) : '讲义' }}</h1>
    <button v-if="lesson" class="flag-btn" :class="{ on: cover }" :aria-pressed="cover" @click="cover = !cover">
      {{ cover ? '显示全部' : '背诵遮盖' }}
    </button>
  </header>
  <main class="page">
    <p v-if="loaded && !lesson" class="muted center">这一节不存在，可能讲义已更新</p>
    <template v-else-if="lesson">
      <div class="row between">
        <span class="muted small clamp">{{ chapterTitle }}</span>
        <span class="state" :class="progress?.state">{{ state }}</span>
      </div>
      <p v-if="cover" class="muted small">点一句话显示它，先自己回忆再看</p>
      <LessonBody :text="lesson.text" :cover="cover" />

      <div v-if="questions.length" class="card col">
        <span>
          本节 {{ questions.length }} 题 · 做过 {{ progress?.answered ?? 0 }}<template v-if="progress?.accuracy != null"> · 最近一次正确率 {{ progress.accuracy }}%</template>
        </span>
      </div>

      <div class="lesson-actions">
        <button v-if="questions.length" class="btn primary block" @click="practise">学完了，做这一节的 {{ questions.length }} 道题</button>
        <button v-else class="btn primary block" @click="done">{{ next ? '学完了，下一节' : '学完了' }}</button>
        <div class="lesson-nav">
          <button class="btn" :disabled="!prev" @click="go(prev)">‹ 上一节</button>
          <button class="btn" :disabled="!next" @click="go(next)">下一节 ›</button>
        </div>
        <button class="btn block muted" @click="setRead(!read)">{{ read ? '✓ 已读（点此取消）' : '标记为已读' }}</button>
      </div>
    </template>
  </main>
</template>
