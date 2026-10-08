<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'
import { dataVersion, formatTime, getRepo, runSync, settings, syncStatus, testConnection } from '@/core/app'
import { ApiError } from '@/data/api'
import GoalPicker from '@/components/GoalPicker.vue'
import { agentSettings, setAgentToken } from '@/core/agent'
import { goals, MAX_MINUTES, MAX_QUESTIONS, updateGoals } from '@/core/goals'

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
      <h2>学习目标</h2>
      <p class="muted small">每天做多少题、学多少分钟，两项可以分别开关；都开时要同时做到才算完成。只存在这台设备上，不会同步。</p>
      <GoalPicker label="每天做题" unit="题" :presets="[10, 20, 30, 50]" :max="MAX_QUESTIONS" :model-value="goals.questions" @update:model-value="updateGoals({ questions: $event })" />
      <GoalPicker label="每天学习" unit="分钟" :presets="[15, 30, 60]" :max="MAX_MINUTES" :model-value="goals.minutes" @update:model-value="updateGoals({ minutes: $event })" />
      <label class="row between">
        <span>每日提醒</span>
        <input type="checkbox" class="switch" :checked="goals.remind" aria-label="每日提醒" @change="updateGoals({ remind: ($event.target as HTMLInputElement).checked })" />
      </label>
      <label v-if="goals.remind" class="row between">
        <span>提醒时间</span>
        <input class="input time-input" type="time" :value="goals.remindAt" aria-label="提醒时间" @change="updateGoals({ remindAt: ($event.target as HTMLInputElement).value })" />
      </label>
      <p class="muted small">提醒只在打开 App 时出现：过了提醒时间、目标还没完成，首页会提示还差多少。不会在后台弹通知。</p>
    </section>

    <section class="card col">
      <h2>AI 助手</h2>
      <p class="muted small">在后台管理页「AI 解读」里设置的访问令牌。填写后，题库页、讲义页和答题解析里才能使用 AI 助手。只存在这台设备上。</p>
      <input
        class="input mono"
        type="password"
        autocomplete="off"
        placeholder="访问令牌"
        aria-label="访问令牌"
        data-testid="ai-token"
        :value="agentSettings.token"
        @change="setAgentToken(($event.target as HTMLInputElement).value)"
      />
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
