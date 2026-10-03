<script setup lang="ts">
import { computed } from 'vue'
import { findQuote, splitByRange } from '@/utils/highlight'

const props = defineProps<{ text: string; quote: string }>()

const range = computed(() => findQuote(props.text, props.quote))
const segments = computed(() => splitByRange(props.text, range.value))
</script>

<template>
  <div>
    <el-alert
      v-if="quote && !range"
      type="warning"
      :closable="false"
      show-icon
      title="在原文中没有找到这条引文"
      description="引文可能被改写过，这道题的依据需要人工核对。"
      style="margin-bottom: 8px"
    />
    <pre class="excerpt"><template v-for="(s, i) in segments" :key="i"><mark v-if="s.mark" class="hit">{{ s.text }}</mark><template v-else>{{ s.text }}</template></template></pre>
  </div>
</template>

<style scoped>
.excerpt {
  white-space: pre-wrap;
  word-break: break-word;
  margin: 0;
  padding: 12px;
  line-height: 1.7;
  font-family: inherit;
  font-size: 14px;
  background: var(--el-fill-color-light);
  border-radius: 6px;
  max-height: 340px;
  overflow: auto;
}
.hit { background: var(--el-color-warning-light-5); color: inherit; border-radius: 2px; padding: 0 1px; }
</style>
