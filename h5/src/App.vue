<script setup lang="ts">
import { watch } from 'vue'
import { useRoute } from 'vue-router'
import TabBar from './components/TabBar.vue'
import { showToast, syncStatus, toast } from './core/app'

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
  <transition name="fade">
    <div v-if="toast.text" :key="toast.seq" class="toast" :class="{ err: toast.error }" role="status">{{ toast.text }}</div>
  </transition>
</template>
