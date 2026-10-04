<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { api, errorMessage } from '@/api/client'
import type { AIConfig, AITestResult } from '@/api/types'

// The key is never sent back by the server: leave the field empty to keep it.
const form = reactive({
  enabled: false,
  base_url: '',
  api_key: '',
  model: '',
  max_tokens: 1500,
  temperature: 0.3,
  app_token: '',
})
const saved = ref<AIConfig | null>(null)
const loading = ref(false)
const saving = ref(false)
const testing = ref(false)
const test = ref<AITestResult | null>(null)

function fill(c: AIConfig) {
  saved.value = c
  Object.assign(form, {
    enabled: c.enabled, base_url: c.base_url, api_key: '', model: c.model,
    max_tokens: c.max_tokens, temperature: c.temperature, app_token: c.app_token,
  })
}

async function load() {
  loading.value = true
  try {
    fill(await api.aiConfig())
  } catch (e) {
    ElMessage.error(errorMessage(e))
  } finally {
    loading.value = false
  }
}

async function save() {
  saving.value = true
  try {
    fill(await api.saveAIConfig({ ...form }))
    test.value = null
    ElMessage.success('已保存，App 下次同步时会拿到新配置')
  } catch (e) {
    ElMessage.error(errorMessage(e))
  } finally {
    saving.value = false
  }
}

async function runTest() {
  testing.value = true
  test.value = null
  try {
    test.value = await api.testAI()
  } catch (e) {
    ElMessage.error(errorMessage(e))
  } finally {
    testing.value = false
  }
}

onMounted(load)
</script>

<template>
  <div>
    <el-form :model="form" label-width="120px" class="form" v-loading="loading">
      <p class="muted intro">
        刷题 App 里的「AI 解读」由 App 直接调用下面这个 OpenAI 兼容接口；这里保存配置，App 同步时用访问令牌取走。
        没有连过服务端的 App 也可以在设置页手动填一份。
      </p>

      <el-form-item label="启用"><el-switch v-model="form.enabled" /></el-form-item>
      <el-form-item label="Base URL">
        <el-input v-model="form.base_url" placeholder="https://api.openai.com/v1" />
        <div class="hint">含版本段（通常是 /v1），App 会在后面拼 /chat/completions。</div>
      </el-form-item>
      <el-form-item label="API Key">
        <el-input v-model="form.api_key" type="password" show-password autocomplete="off"
          :placeholder="saved?.api_key_set ? `已设置（${saved.api_key_hint}），留空则不修改` : 'sk-…'" />
      </el-form-item>
      <el-form-item label="模型"><el-input v-model="form.model" placeholder="gpt-4o-mini / deepseek-chat …" /></el-form-item>
      <el-form-item label="最大输出 token"><el-input-number v-model="form.max_tokens" :min="16" :max="32000" :step="100" /></el-form-item>
      <el-form-item label="Temperature"><el-input-number v-model="form.temperature" :min="0" :max="2" :step="0.1" :precision="1" /></el-form-item>
      <el-form-item label="访问令牌">
        <el-input v-model="form.app_token" placeholder="随便设一个简单的，至少 4 个字符" autocomplete="off" />
        <div class="hint">在 App 设置页输入同一个令牌，才能拉取上面的配置（含 API Key）。留空则没有 App 能拉取。</div>
      </el-form-item>

      <el-form-item>
        <el-button type="primary" :loading="saving" @click="save">保存</el-button>
        <el-button :loading="testing" @click="runTest">测试已保存的配置</el-button>
      </el-form-item>
      <el-alert v-if="test" :type="test.ok ? 'success' : 'error'" :closable="false" show-icon
        :title="test.ok ? `连接成功（${test.latency_ms} ms），模型回复：${test.reply}` : `连接失败：${test.error}`" />
    </el-form>
  </div>
</template>

<style scoped>
.form { max-width: 640px; }
.intro { margin: 0 0 18px; line-height: 1.6; }
.hint { font-size: 12px; color: var(--el-text-color-secondary); line-height: 1.5; margin-top: 4px; width: 100%; }
</style>
