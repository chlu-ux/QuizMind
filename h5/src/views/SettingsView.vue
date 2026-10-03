<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'
import { dataVersion, formatTime, getRepo, runSync, settings, syncStatus, testConnection } from '@/core/app'
import { ApiError } from '@/data/api'

const testing = ref(false)
const result = ref('')
const resultOk = ref(false)
const pending = ref(0)

async function loadPending() {
  pending.value = await (await getRepo()).pendingUploads()
}
onMounted(loadPending)
watch(dataVersion, loadPending)

async function test() {
  testing.value = true
  result.value = ''
  try {
    const n = await testConnection()
    result.value = `连接成功，服务器上有 ${n} 个题库`
    resultOk.value = true
  } catch (e) {
    result.value = e instanceof ApiError ? e.message : String(e)
    resultOk.value = false
  } finally {
    testing.value = false
  }
}

</script>

<template>
  <header class="topbar"><h1>设置</h1></header>
  <main class="page">
    <section class="card col">
      <h2>服务器连接</h2>
      <div class="row">
        <button class="btn" :disabled="testing" @click="test">{{ testing ? '测试中…' : '测试连接' }}</button>
      </div>
      <p v-if="result" :class="resultOk ? 'ok' : 'err'">{{ result }}</p>
    </section>

    <section class="card col">
      <h2>同步</h2>
      <div>上次同步：{{ formatTime(syncStatus.lastSync) }}</div>
      <div class="muted">{{ pending > 0 ? `有 ${pending} 条作答等待上传` : '没有待上传的作答' }}</div>
      <p v-if="syncStatus.message" :class="syncStatus.isError ? 'err' : 'muted'">{{ syncStatus.message }}</p>
      <button class="btn" :disabled="syncStatus.running" @click="runSync">{{ syncStatus.running ? '同步中…' : '立即同步' }}</button>
    </section>

    <section class="card col">
      <h2>本设备</h2>
      <div class="muted small mono">设备 ID：{{ settings.deviceId }}</div>
    </section>
  </main>
</template>
