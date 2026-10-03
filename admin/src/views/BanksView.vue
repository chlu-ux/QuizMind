<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { api, errorMessage } from '@/api/client'
import type { Bank } from '@/api/types'
import { formatTime } from '@/utils/format'

const banks = ref<Bank[]>([])
const loading = ref(false)

async function load() {
  loading.value = true
  try {
    banks.value = await api.banks()
  } catch (e) {
    ElMessage.error(errorMessage(e))
  } finally {
    loading.value = false
  }
}

async function create() {
  try {
    const { value } = await ElMessageBox.prompt('给题库起个名字', '新建题库', { confirmButtonText: '创建', cancelButtonText: '取消' })
    await api.createBank(value, '')
    await load()
  } catch (e) {
    if (e !== 'cancel' && e !== 'close') ElMessage.error(errorMessage(e))
  }
}

onMounted(load)
</script>

<template>
  <div class="page">
    <div class="toolbar">
      <span class="grow" />
      <el-button type="primary" @click="create">新建题库</el-button>
    </div>
    <el-table :data="banks" v-loading="loading" empty-text="还没有题库">
      <el-table-column prop="title" label="题库" min-width="200" />
      <el-table-column label="已发布" width="100">
        <template #default="{ row }">{{ row.question_counts.published ?? 0 }}</template>
      </el-table-column>
      <el-table-column label="待审核" width="100">
        <template #default="{ row }">
          <router-link v-if="row.question_counts.needs_review" :to="{ name: 'review', query: { bank_id: row.id } }">{{ row.question_counts.needs_review }}</router-link>
          <span v-else class="muted">0</span>
        </template>
      </el-table-column>
      <el-table-column label="已驳回" width="100"><template #default="{ row }">{{ row.question_counts.rejected ?? 0 }}</template></el-table-column>
      <el-table-column label="创建时间" width="140"><template #default="{ row }">{{ formatTime(row.created_at) }}</template></el-table-column>
    </el-table>
  </div>
</template>
