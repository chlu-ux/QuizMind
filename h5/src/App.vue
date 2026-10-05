<script setup lang="ts">
import { watch } from 'vue'
import { useRoute } from 'vue-router'
import TabBar from './components/TabBar.vue'
import { showToast, syncStatus, toast } from './core/app'
import { closeImage, lightbox } from './core/lightbox'

const route = useRoute()

// Report a finished sync (success or failure) as a toast.
watch(
  () => syncStatus.running,
  (now, was) => {
    if (was && !now && syncStatus.message) showToast(syncStatus.message, syncStatus.isError)
  },
)
</script>

<template>
  <div class="shell" :class="{ withTabs: route.meta.tabs }">
    <router-view v-slot="{ Component }">
      <component :is="Component" />
    </router-view>
  </div>
  <TabBar v-if="route.meta.tabs" />
  <div v-if="lightbox.src" class="lightbox" role="dialog" aria-label="查看图片" @click="closeImage">
    <img :src="lightbox.src" :alt="lightbox.alt" />
  </div>
  <transition name="fade">
    <div v-if="toast.text" :key="toast.seq" class="toast" :class="{ err: toast.error }" role="status">{{ toast.text }}</div>
  </transition>
</template>
