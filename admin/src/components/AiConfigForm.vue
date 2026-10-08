<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { api, errorMessage } from '@/api/client'
import type { AIConfig } from '@/api/types'

const form = reactive({ enabled: false, app_token: '', review_agent_questions: false })
const saved = ref<AIConfig | null>(null)
const loading = ref(false)
const saving = ref(false)

function fill(c: AIConfig) {
  saved.value = c
  Object.assign(form, { enabled: c.enabled, app_token: c.app_token, review_agent_questions: c.review_agent_questions })
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
    ElMessage.success('已保存，App 下次同步时会拿到新配置')
  } catch (e) {
    ElMessage.error(errorMessage(e))
  } finally {
    saving.value = false
  }
}

onMounted(load)
</script>

<template>
  <div>
    <el-form :model="form" label-width="120px" class="form" v-loading="loading">
      <p class="muted intro">
        刷题 App 里的「AI 解读」由 App 直接调用一个 OpenAI 兼容的模型。模型在「模型与角色」里配置并指定给「AI 解读」角色；
        这里决定是否启用，以及 App 用什么访问令牌来取走配置（含 API Key）。没有连过服务端的 App 也可以在设置页手动填一份。
      </p>

      <el-form-item label="使用的模型">
        <span v-if="saved?.model_name">{{ saved.model_name }}</span>
        <span v-else class="muted">还没有指定，请到「模型与角色」里为「AI 解读」选一个 OpenAI 协议的模型</span>
      </el-form-item>
      <el-form-item label="启用"><el-switch v-model="form.enabled" /></el-form-item>
      <el-form-item label="访问令牌">
        <el-input v-model="form.app_token" placeholder="随便设一个简单的，至少 4 个字符" autocomplete="off" />
        <div class="hint">在 App 或 H5 的设置页输入同一个令牌，才能拉取配置、上报用量和使用 AI 助手。留空则都不能用。</div>
      </el-form-item>
      <el-form-item label="助手出的题">
        <el-switch v-model="form.review_agent_questions" active-text="先审核再发布" inactive-text="直接发布" />
        <div class="hint">
          在 AI 助手里让它出题，通过检查的题默认就算“采纳”：关闭时立刻进入题库，学习者可以在卡片上取消采纳；打开时先进入审核队列，由你在审核页通过后才发布。
        </div>
      </el-form-item>

      <el-form-item>
        <el-button type="primary" :loading="saving" @click="save">保存</el-button>
      </el-form-item>
    </el-form>
  </div>
</template>

<style scoped>
.form { max-width: 640px; }
.intro { margin: 0 0 18px; line-height: 1.6; }
.hint { font-size: 12px; color: var(--el-text-color-secondary); line-height: 1.5; margin-top: 4px; width: 100%; }
</style>
