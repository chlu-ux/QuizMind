<script setup lang="ts">
import { computed } from 'vue'
import { openImage } from '@/core/lightbox'
import { segments } from '@/quiz/media'

const props = defineProps<{ text: string }>()
const parts = computed(() => segments(props.text))
</script>

<template>
  <span class="opt-text">
    <template v-for="(p, i) in parts" :key="i">
      <img
        v-if="p.kind === 'image'"
        class="qimg"
        :src="p.src"
        :alt="p.alt"
        loading="lazy"
        @click.stop="openImage(p.src, p.alt)"
      />
      <template v-else>{{ p.text }}</template>
    </template>
  </span>
</template>
