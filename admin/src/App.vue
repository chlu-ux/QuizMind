<script setup lang="ts">
import { computed, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { Collection, Document, List, Monitor, TrendCharts, Checked } from '@element-plus/icons-vue'
import { useAuth } from '@/stores/auth'
import { useEvents } from '@/stores/events'

const route = useRoute()
const router = useRouter()
const auth = useAuth()
const events = useEvents()

const showShell = computed(() => !route.meta.public)

// Open the live-progress stream once we are signed in; close it on sign-out.
// Only redirect after the initial auth check has finished, otherwise a page
// reload would bounce to the login screen before the stored token is verified.
watch(
  () => [auth.authed, auth.checked] as const,
  ([ok, checked]) => {
    if (ok) events.connect()
    else {
      events.disconnect()
      if (checked && !route.meta.public) router.replace({ name: 'login', query: { redirect: route.fullPath } })
    }
  },
  { immediate: true },
)

function logout() {
  auth.logout()
}
</script>

<template>
  <router-view v-if="!showShell" />
  <el-container v-else style="height: 100%">
    <el-aside width="168px" class="aside">
      <div class="brand">QuizMind</div>
      <el-menu :default-active="route.path" router class="menu">
        <el-menu-item index="/documents"><el-icon><Document /></el-icon>文档</el-menu-item>
        <el-menu-item index="/review"><el-icon><Checked /></el-icon>审核</el-menu-item>
        <el-menu-item index="/banks"><el-icon><Collection /></el-icon>题库</el-menu-item>
        <el-menu-item index="/jobs"><el-icon><List /></el-icon>任务</el-menu-item>
        <el-menu-item index="/usage"><el-icon><TrendCharts /></el-icon>用量</el-menu-item>
      </el-menu>
      <div class="aside-foot">
        <el-tooltip :content="events.connected ? '实时进度已连接' : '实时进度未连接，页面不会自动刷新'" placement="right">
          <span class="live" :class="{ on: events.connected }"><el-icon><Monitor /></el-icon>{{ events.connected ? '实时' : '离线' }}</span>
        </el-tooltip>
        <el-button v-if="auth.token" link size="small" @click="logout">退出</el-button>
      </div>
    </el-aside>
    <el-main style="padding: 0; overflow: auto"><router-view /></el-main>
  </el-container>
</template>

<style scoped>
.aside { display: flex; flex-direction: column; border-right: 1px solid var(--el-border-color); }
.brand { font-weight: 700; font-size: 18px; padding: 16px 20px; }
.menu { border-right: none; flex: 1; }
.aside-foot { padding: 10px 16px; display: flex; justify-content: space-between; align-items: center; }
.live { font-size: 12px; color: var(--el-text-color-secondary); display: inline-flex; align-items: center; gap: 4px; }
.live.on { color: var(--el-color-success); }
</style>
