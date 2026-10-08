<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'
import { ElMessage } from 'element-plus'
import { api, errorMessage } from '@/api/client'
import type { UsageCall } from '@/api/types'
import { plainText } from '@/utils/media'
import { formatNumber, formatTime } from '@/utils/format'
import { ROLE_LABEL, SOURCE_LABEL } from '@/utils/usage'

const props = defineProps<{ days: number; source: string; role: string }>()

const PAGE_SIZE = 20
const page = ref(1)
const total = ref(0)
const items = ref<UsageCall[]>([])
const failedOnly = ref(false)
const loading = ref(false)

async function load() {
  loading.value = true
  try {
    const r = await api.usageCalls({
      days: props.days,
      source: props.source || undefined,
      role: props.role || undefined,
      failed: failedOnly.value ? 1 : undefined,
      limit: PAGE_SIZE,
      offset: (page.value - 1) * PAGE_SIZE,
    })
    items.value = r.items
    total.value = r.total
  } catch (e) {
    ElMessage.error(errorMessage(e))
  } finally {
    loading.value = false
  }
}

// A new filter starts from the first page; the page watcher then reloads.
watch(
  () => [props.days, props.source, props.role, failedOnly.value],
  () => {
    if (page.value === 1) void load()
    else page.value = 1
  },
)
watch(page, load)
onMounted(load)

const who = (c: UsageCall) => (c.source === 'client' ? `设备 ${c.device_id.slice(-6) || '?'}` : SOURCE_LABEL[c.source])
</script>

<template>
  <div>
    <div class="bar">
      <el-checkbox v-model="failedOnly">只看失败</el-checkbox>
      <span class="muted">共 {{ formatNumber(total) }} 次调用</span>
    </div>
    <el-table :data="items" v-loading="loading" empty-text="没有符合条件的调用" size="small">
      <el-table-column label="时间" width="120"><template #default="{ row }">{{ formatTime(row.created_at) }}</template></el-table-column>
      <el-table-column label="来源" width="120"><template #default="{ row }">{{ who(row) }}</template></el-table-column>
      <el-table-column label="角色" width="90"><template #default="{ row }">{{ ROLE_LABEL[row.role] ?? row.role }}</template></el-table-column>
      <el-table-column prop="model" label="模型" min-width="130" show-overflow-tooltip />
      <el-table-column label="输入" width="90"><template #default="{ row }">{{ formatNumber(row.input_tokens) }}</template></el-table-column>
      <el-table-column label="输出" width="90">
        <template #default="{ row }">
          {{ formatNumber(row.output_tokens) }}
          <el-tooltip v-if="row.estimated" content="接口没有返回 token 数，这是 App 按字数估算的"><el-tag size="small" type="info">估</el-tag></el-tooltip>
        </template>
      </el-table-column>
      <el-table-column label="缓存" width="80"><template #default="{ row }">{{ formatNumber(row.cached_tokens) }}</template></el-table-column>
      <el-table-column label="耗时" width="80"><template #default="{ row }">{{ (row.latency_ms / 1000).toFixed(1) }} s</template></el-table-column>
      <el-table-column label="结果" width="80">
        <template #default="{ row }">
          <el-tooltip v-if="!row.ok" :content="row.error || '失败'"><el-tag size="small" type="danger">失败</el-tag></el-tooltip>
          <span v-else class="ok">成功</span>
        </template>
      </el-table-column>
      <el-table-column label="题目" min-width="240">
        <template #default="{ row }">
          <el-tooltip v-if="row.question_stem" :content="`${row.bank_title}：${plainText(row.question_stem)}`" placement="top-start">
            <span class="stem">{{ plainText(row.question_stem) }}</span>
          </el-tooltip>
          <span v-else-if="row.job_id" class="muted">任务 {{ row.job_id.slice(-6) }}</span>
          <span v-else class="muted">-</span>
        </template>
      </el-table-column>
    </el-table>
    <el-pagination v-if="total > PAGE_SIZE" v-model:current-page="page" class="pager" layout="prev, pager, next" :page-size="PAGE_SIZE" :total="total" />
  </div>
</template>

<style scoped>
.bar { display: flex; align-items: center; gap: 16px; margin-bottom: 10px; }
.muted { color: var(--el-text-color-secondary); font-size: 13px; }
.ok { color: var(--el-color-success); }
.stem { display: inline-block; max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; vertical-align: bottom; }
.pager { margin-top: 12px; justify-content: center; }
</style>
