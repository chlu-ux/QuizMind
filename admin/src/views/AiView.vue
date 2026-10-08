<script setup lang="ts">
import { ref } from 'vue'
import AiConfigForm from '@/components/AiConfigForm.vue'
import LlmSettings from '@/components/LlmSettings.vue'
import AiNotes from '@/components/AiNotes.vue'

const tab = ref('models')
</script>

<template>
  <div class="page">
    <el-tabs v-model="tab">
      <el-tab-pane label="模型与角色" name="models"><LlmSettings /></el-tab-pane>
      <el-tab-pane label="AI 解读" name="config" lazy><AiConfigForm /></el-tab-pane>
      <el-tab-pane label="解读记录" name="notes" lazy><AiNotes /></el-tab-pane>
    </el-tabs>
  </div>
</template>
