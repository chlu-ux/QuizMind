<script setup lang="ts">
import { ref } from 'vue'
import AiConfigForm from '@/components/AiConfigForm.vue'
import AiNotes from '@/components/AiNotes.vue'

const tab = ref('config')
</script>

<template>
  <div class="page">
    <el-tabs v-model="tab">
      <el-tab-pane label="配置" name="config"><AiConfigForm /></el-tab-pane>
      <el-tab-pane label="解读记录" name="notes" lazy><AiNotes /></el-tab-pane>
    </el-tabs>
  </div>
</template>
