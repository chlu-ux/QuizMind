<script setup lang="ts">
import { ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useAuth } from '@/stores/auth'

const auth = useAuth()
const route = useRoute()
const router = useRouter()
const token = ref('')
const busy = ref(false)
const failed = ref(false)

async function submit() {
  busy.value = true
  failed.value = false
  const ok = await auth.login(token.value.trim())
  busy.value = false
  if (ok) router.replace((route.query.redirect as string) || '/')
  else failed.value = true
}
</script>

<template>
  <div class="wrap">
    <el-card class="card" shadow="hover">
      <h2>QuizMind 管理后台</h2>
      <p class="muted">输入服务端的访问令牌（环境变量 <code>QUIZMIND_TOKEN</code>）。</p>
      <el-form @submit.prevent="submit">
        <el-input v-model="token" type="password" show-password placeholder="访问令牌" autofocus size="large" />
        <el-alert v-if="failed" type="error" :closable="false" title="令牌无效，或无法连接到服务端" style="margin-top: 12px" />
        <el-button type="primary" native-type="submit" :loading="busy" size="large" style="width: 100%; margin-top: 16px">进入</el-button>
      </el-form>
    </el-card>
  </div>
</template>

<style scoped>
.wrap { height: 100%; display: flex; align-items: center; justify-content: center; }
.card { width: 380px; }
h2 { margin-top: 0; }
</style>
