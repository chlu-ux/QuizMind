<script setup lang="ts">
import { onMounted, ref } from 'vue'

// A picture the learner gave the assistant, as a small button that opens it large.
const props = defineProps<{
  /** Gives the address to show the picture by (it may need a fetch, so it is asked for when shown). */
  load: () => Promise<string>
  name: string
}>()
const emit = defineEmits<{ open: [url: string, name: string] }>()

const url = ref('')
const failed = ref(false)

onMounted(async () => {
  try {
    url.value = await props.load()
  } catch {
    failed.value = true
  }
})
</script>

<template>
  <button
    type="button"
    class="thumb"
    :aria-label="`查看图片 ${name}`"
    :disabled="!url"
    data-testid="agent-image"
    @click="emit('open', url, name)"
  >
    <img v-if="url" :src="url" :alt="name" />
    <span v-else-if="failed" class="small muted">无法显示</span>
    <span v-else class="spin muted">◌</span>
  </button>
</template>
