<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'
import SyncButton from '@/components/SyncButton.vue'
import { dataVersion, getRepo, runSync, syncStatus } from '@/core/app'
import type { Bank } from '@/data/types'

const banks = ref<Bank[] | null>(null)

async function load() {
  banks.value = await (await getRepo()).banks()
}
onMounted(load)
watch(dataVersion, load)
</script>

<template>
  <header class="topbar">
    <h1>题库</h1>
    <SyncButton />
  </header>
  <main class="page">
    <p v-if="banks === null" class="muted center">加载中…</p>
    <template v-else-if="banks.length === 0">
      <div class="empty">
        <div class="big">☁️</div>
        <p v-if="syncStatus.isError">{{ syncStatus.message }}</p>
        <p v-else>还没有题库。先在管理后台上传文档并审核发布，再点右上角同步。</p>
        <button class="btn primary" :disabled="syncStatus.running" @click="runSync">立即同步</button>
      </div>
    </template>
    <router-link v-for="b in banks" v-else :key="b.id" :to="`/bank/${b.id}`" class="card link">
      <div class="grow">
        <div class="title">{{ b.title }}</div>
        <div v-if="b.description" class="muted clamp">{{ b.description }}</div>
      </div>
      <div class="count">{{ b.question_count }} 题</div>
    </router-link>
  </main>
</template>
