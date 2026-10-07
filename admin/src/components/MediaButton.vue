<script setup lang="ts">
import { ref } from 'vue'
import { ElMessage } from 'element-plus'
import { api, errorMessage } from '@/api/client'

const emit = defineEmits<{ (e: 'inserted', ref: string): void }>()

const input = ref<HTMLInputElement>()
const busy = ref(false)

/** Uploads one picture and reports the Markdown reference to insert. */
async function send(file: File | Blob) {
  busy.value = true
  try {
    emit('inserted', (await api.uploadMedia(file)).ref)
  } catch (e) {
    ElMessage.error(errorMessage(e))
  } finally {
    busy.value = false
  }
}

async function chosen() {
  const file = input.value?.files?.[0]
  if (input.value) input.value.value = '' // so choosing the same file again still fires
  if (file) await send(file)
}

defineExpose({ send })
</script>

<template>
  <el-button size="small" :loading="busy" @click="input?.click()">插入图片</el-button>
  <input ref="input" type="file" accept="image/svg+xml,image/png,image/jpeg,image/gif,image/webp" hidden @change="chosen" />
</template>
