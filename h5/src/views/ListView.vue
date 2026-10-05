<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { useRoute } from 'vue-router'
import SyncButton from '@/components/SyncButton.vue'
import { bump, dataVersion, getRepo } from '@/core/app'
import type { Bank, LocalQuestion } from '@/data/types'
import { bankOptions, inBank, rememberBank, rememberedBank } from '@/quiz/bankFilter'
import { plainText } from '@/quiz/media'
import { orderQuestions } from '@/quiz/session'
import { startQuiz } from '@/quiz/launch'

const props = defineProps<{ kind: 'wrong' | 'fav' }>()
const route = useRoute()
const wrong = computed(() => props.kind === 'wrong')
const base = computed(() => (wrong.value ? '错题本' : '收藏'))
const all = ref<LocalQuestion[] | null>(null)
const banks = ref<Bank[]>([])
// '' = every bank. Coming from a bank page (?bank=) wins over what was picked last in this session.
const bankId = ref('')

const options = computed(() => bankOptions(all.value ?? [], banks.value))
// A bank with nothing left on the list cannot stay selected: fall back to showing everything.
const active = computed(() => (options.value.some((o) => o.id === bankId.value) ? bankId.value : ''))
const items = computed(() => (all.value ? inBank(all.value, active.value) : null))
const bankName = (id: string) => options.value.find((o) => o.id === id)?.name ?? ''
const title = computed(() => (active.value ? `${base.value} · ${bankName(active.value)}` : base.value))

function pick(id: string) {
  bankId.value = id
  rememberBank(props.kind, id)
}

function initialBank(): string {
  const q = route.query.bank
  const fromRoute = typeof q === 'string' ? q : ''
  return fromRoute || rememberedBank(props.kind)
}

async function load() {
  const repo = await getRepo()
  banks.value = await repo.banks()
  all.value = wrong.value ? await repo.wrongBook() : await repo.favorites()
}
onMounted(async () => {
  bankId.value = initialBank()
  await load()
})
watch([dataVersion, () => props.kind], load)
watch(
  () => props.kind,
  () => (bankId.value = initialBank()),
)
watch(
  () => route.query.bank,
  (b) => {
    if (typeof b === 'string' && b) pick(b)
  },
)

async function remove(q: LocalQuestion) {
  const repo = await getRepo()
  if (wrong.value) await repo.clearFromWrongBook(q.id)
  else await repo.setFavorite(q.id, false)
  bump()
}
</script>

<template>
  <header class="topbar">
    <h1>{{ base }}</h1>
    <SyncButton />
  </header>
  <main class="page">
    <p v-if="items === null" class="muted center">加载中…</p>
    <div v-else-if="all!.length === 0" class="empty">
      <div class="big">{{ wrong ? '🎉' : '⭐' }}</div>
      <p>{{ wrong ? '没有错题，继续保持' : '还没有收藏的题目' }}</p>
    </div>
    <template v-else>
      <div v-if="options.length > 1 || active" class="chips bank-filter" role="group" aria-label="按题库筛选">
        <button class="pick" :class="{ on: !active }" @click="pick('')">全部 <small>{{ all!.length }}</small></button>
        <button v-for="o in options" :key="o.id" class="pick" :class="{ on: active === o.id }" @click="pick(o.id)">
          {{ o.name }} <small>{{ o.count }}</small>
        </button>
      </div>
      <div class="row between">
        <span class="muted">共 {{ items.length }} 题</span>
        <button class="btn primary" @click="startQuiz(title, orderQuestions(items, 'random'))">随机练习</button>
      </div>
      <div v-for="(q, i) in items" :key="q.id" class="card">
        <button class="grow plain" @click="startQuiz(title, items, i)">
          <div class="clamp2">{{ plainText(q.stem) }}</div>
          <div class="muted small">
            {{ q.type === 'judge' ? '判断题' : '单选题' }}
            <template v-if="!active"> · {{ bankName(q.bank_id) }}</template>
          </div>
        </button>
        <button class="icon-btn" :aria-label="wrong ? '移出错题本' : '取消收藏'" @click="remove(q)">
          {{ wrong ? '✓' : '★' }}
        </button>
      </div>
    </template>
  </main>
</template>
