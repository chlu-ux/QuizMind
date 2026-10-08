<script setup lang="ts">
import { computed, reactive, ref } from 'vue'
import Md from '@/components/Md.vue'
import type { DraftEntry } from '@/quiz/agentChat'

/**
 * The questions the assistant wrote in one answer, as one compact card: a line per question with a
 * switch for adopting it, and the question itself unfolding when tapped. A long run of questions
 * takes a screen or two instead of a page each.
 */
const props = defineProps<{ entries: DraftEntry[] }>()
const emit = defineEmits<{ accept: [id: string]; discard: [id: string]; revise: [id: string]; setAll: [ids: string[], adopt: boolean] }>()

/** Questions shown unfolded. One or two are shown at once; more are folded up until tapped. */
const open = reactive(new Set<string>(props.entries.length <= 2 ? props.entries.map((e) => e.draft.id) : []))
/** Folded up as a whole, leaving the header. */
const folded = ref(false)

const adopted = computed(() => props.entries.filter((e) => e.phase === 'accepted').length)
const busy = computed(() => props.entries.some((e) => e.phase === 'working'))
const allAdopted = computed(() => adopted.value === props.entries.length)
const ids = computed(() => props.entries.map((e) => e.draft.id))

function toggleOpen(id: string) {
  if (!open.delete(id)) open.add(id)
}
function change(e: DraftEntry, on: boolean) {
  if (on) emit('accept', e.draft.id)
  else emit('discard', e.draft.id)
}
const stars = (n: number) => '★'.repeat(Math.min(5, Math.max(1, n)))
const flat = (s: string) => s.replace(/\s+/g, ' ')
</script>

<template>
  <div class="draft-group card col" data-testid="draft-group">
    <div class="draft-head row gap" data-testid="drafts-header" @click="folded = !folded">
      <div class="grow">
        <strong>出了 {{ entries.length }} 道题</strong>
        <div class="muted small" data-testid="drafts-summary">已采纳 {{ adopted }} 道 · 采纳的题在题库里，可随时取消</div>
      </div>
      <button v-if="entries.length > 1" class="btn small" :disabled="busy" data-testid="drafts-all" @click.stop="emit('setAll', ids, !allAdopted)">
        {{ allAdopted ? '全部取消' : '全部采纳' }}
      </button>
      <span class="muted" aria-hidden="true">{{ folded ? '▾' : '▴' }}</span>
    </div>
    <template v-if="!folded">
      <div v-for="(e, i) in entries" :key="e.draft.id" class="draft-item" data-testid="draft-card">
        <div class="draft-line row gap" :data-testid="`draft-row-${e.draft.id}`" @click="toggleOpen(e.draft.id)">
          <span class="muted num">{{ i + 1 }}</span>
          <div class="grow">
            <div :class="['stem', { clamp2: !open.has(e.draft.id), off: e.phase !== 'accepted' }]">{{ flat(e.draft.stem) }}</div>
            <div class="muted small">
              {{ e.draft.type === 'judge' ? '判断题' : '单选题' }} · 难度 {{ stars(e.draft.difficulty) }}<template v-if="!e.draft.verified"> · 未经独立复核</template>
            </div>
          </div>
          <span v-if="e.phase === 'working'" class="muted spin" aria-label="处理中">◌</span>
          <input
            v-else
            type="checkbox"
            class="switch"
            role="switch"
            :checked="e.phase === 'accepted'"
            :aria-label="e.phase === 'accepted' ? '取消采纳' : '采纳'"
            :data-testid="`draft-switch-${e.draft.id}`"
            @click.stop
            @change="change(e, ($event.target as HTMLInputElement).checked)"
          />
        </div>
        <div v-if="open.has(e.draft.id)" class="draft-body col">
          <Md :source="e.draft.stem" />
          <div v-for="(o, k) in e.draft.options" :key="k" class="draft-opt" :class="{ right: k === e.draft.answerIndex }">
            <span class="letter">{{ String.fromCharCode(65 + k) }}.</span>
            <span class="grow">{{ o }}</span>
            <span v-if="k === e.draft.answerIndex" aria-label="正确答案">✔</span>
          </div>
          <template v-if="e.draft.explanation">
            <strong class="small">解析</strong>
            <Md :source="e.draft.explanation" />
          </template>
          <template v-if="e.draft.sourceQuote">
            <strong class="small">出处原文</strong>
            <p class="small muted">「{{ e.draft.sourceQuote }}」</p>
          </template>
          <p v-if="e.error" class="err small">{{ e.error }}</p>
          <div class="row"><button class="btn small" :disabled="e.phase === 'working'" :data-testid="`draft-revise-${e.draft.id}`" @click="emit('revise', e.draft.id)">让它改改</button></div>
        </div>
        <p v-else-if="e.error" class="err small draft-err">{{ e.error }}</p>
      </div>
    </template>
  </div>
</template>
