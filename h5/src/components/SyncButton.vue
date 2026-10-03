<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { dataVersion, getRepo, runSync, syncStatus } from '@/core/app'
import { watch } from 'vue'

const pending = ref(0)
async function load() {
  pending.value = await (await getRepo()).pendingUploads()
}
onMounted(load)
watch(dataVersion, load)
</script>

<template>
  <button class="icon-btn" :disabled="syncStatus.running" aria-label="同步" @click="runSync">
    <span :class="{ spin: syncStatus.running }">⟳</span>
    <i v-if="pending > 0" class="badge">{{ pending }}</i>
  </button>
</template>
