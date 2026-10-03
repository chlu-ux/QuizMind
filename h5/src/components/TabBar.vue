<script setup lang="ts">
import { useRoute } from 'vue-router'

const route = useRoute()
const tabs = [
  { to: '/', label: '题库', icon: '📚' },
  { to: '/wrong', label: '错题本', icon: '📕' },
  { to: '/fav', label: '收藏', icon: '⭐' },
  { to: '/settings', label: '设置', icon: '⚙️' },
]
const active = (to: string) => (to === '/' ? route.path === '/' || route.path.startsWith('/bank') : route.path === to)
</script>

<template>
  <nav class="tabbar">
    <router-link v-for="t in tabs" :key="t.to" :to="t.to" :class="{ on: active(t.to) }">
      <span class="ico">{{ t.icon }}</span>
      <span>{{ t.label }}</span>
    </router-link>
  </nav>
</template>
