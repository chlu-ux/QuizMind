<script setup lang="ts">
import Md from '@/components/Md.vue'
import type { DraftEntry } from '@/quiz/agentChat'

defineProps<{ entry: DraftEntry }>()
defineEmits<{ accept: []; discard: []; revise: [] }>()
</script>

<template>
  <div class="draft card col" :class="{ discarded: entry.phase === 'discarded' }" data-testid="draft-card">
    <div class="row gap wrap">
      <span class="chip">{{ entry.draft.type === 'judge' ? '判断题' : '单选题' }}</span>
      <span class="chip">难度 {{ '★'.repeat(Math.min(5, Math.max(1, entry.draft.difficulty))) }}</span>
      <span v-for="t in entry.draft.tags" :key="t" class="chip">{{ t }}</span>
      <span v-if="!entry.draft.verified" class="small unverified">未经独立复核</span>
    </div>
    <Md :source="entry.draft.stem" />
    <div v-for="(o, i) in entry.draft.options" :key="i" class="draft-opt" :class="{ right: i === entry.draft.answerIndex }">
      <span class="letter">{{ String.fromCharCode(65 + i) }}.</span>
      <span class="grow">{{ o }}</span>
      <span v-if="i === entry.draft.answerIndex" aria-label="正确答案">✔</span>
    </div>
    <template v-if="entry.draft.explanation">
      <strong class="small">解析</strong>
      <Md :source="entry.draft.explanation" />
    </template>
    <details v-if="entry.draft.sourceQuote">
      <summary class="small">出处原文</summary>
      <p class="small muted">「{{ entry.draft.sourceQuote }}」</p>
    </details>
    <p v-if="entry.error" class="err small">{{ entry.error }}</p>
    <div v-if="entry.phase === 'accepted'" class="ok small">已提交审核，通过后会出现在题库里</div>
    <div v-else-if="entry.phase === 'discarded'" class="muted small">已丢弃</div>
    <div v-else class="row gap wrap">
      <button class="btn primary" :disabled="entry.phase === 'working'" @click="$emit('accept')">
        {{ entry.phase === 'working' ? '处理中…' : '采纳' }}
      </button>
      <button class="btn" :disabled="entry.phase === 'working'" @click="$emit('revise')">让它改改</button>
      <button class="btn" :disabled="entry.phase === 'working'" @click="$emit('discard')">丢弃</button>
    </div>
  </div>
</template>
