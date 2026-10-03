<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { ElMessage } from 'element-plus'
import { api, errorMessage } from '@/api/client'
import type { Job } from '@/api/types'
import StatusTag from '@/components/StatusTag.vue'
import { useEvents } from '@/stores/events'
import { debounce } from '@/utils/debounce'
import { formatTime, JOB_STATUS_LABEL, JOB_TYPE_LABEL } from '@/utils/format'

const events = useEvents()
const jobs = ref<Job[]>([])
const status = ref('')
const loading = ref(false)

async function load() {
  loading.value = true
  try {
    jobs.value = await api.jobs({ status: status.value || undefined, limit: 200 })
  } catch (e) {
    ElMessage.error(errorMessage(e))
  } finally {
    loading.value = false
  }
}
const reload = debounce(load, 250)

async function retry(id: string) {
  try {
    await api.retryJob(id)
    ElMessage.success('已重新排队')
    await load()
  } catch (e) {
    ElMessage.error(errorMessage(e))
  }
}

watch(status, load)
let off: (() => void) | undefined
onMounted(() => {
  load()
  off = events.on((e) => e.type === 'job' && reload())
})
onBeforeUnmount(() => {
  off?.()
  reload.cancel()
})
</script>

<template>
  <div class="page">
    <div class="toolbar">
      <el-select v-model="status" clearable placeholder="全部状态" style="width: 140px">
        <el-option v-for="(label, key) in JOB_STATUS_LABEL" :key="key" :label="label" :value="key" />
      </el-select>
      <el-button @click="load">刷新</el-button>
    </div>
    <el-table :data="jobs" v-loading="loading" empty-text="没有任务">
      <el-table-column label="类型" width="120"><template #default="{ row }">{{ JOB_TYPE_LABEL[row.type] ?? row.type }}</template></el-table-column>
      <el-table-column label="状态" width="100"><template #default="{ row }"><StatusTag kind="job" :status="row.status" /></template></el-table-column>
      <el-table-column label="尝试" width="80"><template #default="{ row }">{{ row.attempts }}/{{ row.max_attempts }}</template></el-table-column>
      <el-table-column label="错误" min-width="280" show-overflow-tooltip>
        <template #default="{ row }"><span class="err">{{ row.last_error }}</span></template>
      </el-table-column>
      <el-table-column label="创建" width="120"><template #default="{ row }">{{ formatTime(row.created_at) }}</template></el-table-column>
      <el-table-column label="" width="100" align="right">
        <template #default="{ row }"><el-button v-if="row.status === 'failed'" size="small" @click="retry(row.id)">重试</el-button></template>
      </el-table-column>
    </el-table>
  </div>
</template>

<style scoped>
.err { color: var(--el-color-danger); }
</style>
