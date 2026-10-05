<script setup lang="ts">
import type { Question } from '@/api/types'
import Markdown from '@/components/Markdown.vue'
import OptText from '@/components/OptText.vue'
import { OPTION_LETTERS, TYPE_LABEL } from '@/utils/format'

defineProps<{ q: Pick<Question, 'type' | 'stem' | 'options' | 'answer' | 'difficulty' | 'tags'> }>()
</script>

<template>
  <div class="qcard">
    <div class="meta">
      <el-tag size="small" effect="plain">{{ TYPE_LABEL[q.type] ?? q.type }}</el-tag>
      <el-rate :model-value="q.difficulty" disabled :max="5" size="small" />
      <el-tag v-for="t in q.tags" :key="t" size="small" type="info" effect="plain">{{ t }}</el-tag>
    </div>
    <Markdown class="stem" :source="q.stem" />
    <ul class="options">
      <li v-for="(o, i) in q.options" :key="i" :class="{ correct: q.answer.includes(i) }">
        <span class="letter">{{ OPTION_LETTERS[i] }}</span>
        <OptText class="text" :text="o" />
        <span v-if="q.answer.includes(i)" class="tick">✓ 正确答案</span>
      </li>
    </ul>
  </div>
</template>

<style scoped>
.meta { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; margin-bottom: 8px; }
.stem { font-size: 16px; line-height: 1.6; font-weight: 600; margin-bottom: 10px; }
.options { list-style: none; padding: 0; margin: 0; display: flex; flex-direction: column; gap: 6px; }
.options li { display: flex; gap: 10px; align-items: baseline; padding: 8px 12px; border: 1px solid var(--el-border-color); border-radius: 6px; }
.options li.correct { border-color: var(--el-color-success); background: var(--el-color-success-light-9); }
.letter { font-weight: 700; width: 18px; color: var(--el-text-color-secondary); }
.text { flex: 1; }
.tick { color: var(--el-color-success); font-size: 12px; white-space: nowrap; }
</style>
