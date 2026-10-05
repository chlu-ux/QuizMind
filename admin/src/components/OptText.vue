<script setup lang="ts">
import { computed } from 'vue'
import { segments } from '@/utils/media'

const props = defineProps<{ text: string }>()
const parts = computed(() => segments(props.text))
</script>

<template>
  <span class="opt-text">
    <template v-for="(p, i) in parts" :key="i">
      <a v-if="p.kind === 'image'" :href="p.src" target="_blank" rel="noopener" class="pic">
        <img :src="p.src" :alt="p.alt" loading="lazy" />
      </a>
      <template v-else>{{ p.text }}</template>
    </template>
  </span>
</template>

<style scoped>
.pic { display: block; width: fit-content; max-width: 100%; }
img { display: block; max-width: 100%; max-height: 320px; padding: 4px; border-radius: 4px; background: #fff; border: 1px solid var(--el-border-color); }
</style>
