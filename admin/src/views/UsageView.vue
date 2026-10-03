<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { ElMessage } from 'element-plus'
import { api, errorMessage } from '@/api/client'
import type { UsageRow } from '@/api/types'
import { formatNumber } from '@/utils/format'

const days = ref(30)
const rows = ref<UsageRow[]>([])
const loading = ref(false)

const totals = computed(() =>
  rows.value.reduce(
    (a, r) => ({
      calls: a.calls + r.calls,
      input: a.input + r.input_tokens,
      output: a.output + r.output_tokens,
      cached: a.cached + r.cached_tokens,
      failures: a.failures + r.failures,
    }),
    { calls: 0, input: 0, output: 0, cached: 0, failures: 0 },
  ),
)
const cacheRate = computed(() => {
  const denom = totals.value.input + totals.value.cached
  return denom ? Math.round((totals.value.cached / denom) * 100) : 0
})

async function load() {
  loading.value = true
  try {
    rows.value = await api.usage(days.value)
  } catch (e) {
    ElMessage.error(errorMessage(e))
  } finally {
    loading.value = false
  }
}

watch(days, load)
onMounted(load)
</script>

<template>
  <div class="page">
    <div class="toolbar">
      <el-select v-model="days" style="width: 140px">
        <el-option :value="7" label="最近 7 天" />
        <el-option :value="30" label="最近 30 天" />
        <el-option :value="90" label="最近 90 天" />
      </el-select>
      <span class="muted">只统计 token 数；单价请对照模型的价格表自行换算。</span>
    </div>

    <el-row :gutter="12" class="stats">
      <el-col :span="6"><el-statistic title="调用次数" :value="totals.calls" /></el-col>
      <el-col :span="6"><el-statistic title="输入 token" :value="totals.input" /></el-col>
      <el-col :span="6"><el-statistic title="输出 token" :value="totals.output" /></el-col>
      <el-col :span="6"><el-statistic title="缓存命中" :value="cacheRate" suffix="%" /></el-col>
    </el-row>

    <el-table :data="rows" v-loading="loading" empty-text="这段时间没有调用记录">
      <el-table-column prop="day" label="日期" width="120" />
      <el-table-column prop="model" label="模型" min-width="180" />
      <el-table-column label="调用" width="90"><template #default="{ row }">{{ row.calls }}</template></el-table-column>
      <el-table-column label="输入" width="120"><template #default="{ row }">{{ formatNumber(row.input_tokens) }}</template></el-table-column>
      <el-table-column label="输出" width="120"><template #default="{ row }">{{ formatNumber(row.output_tokens) }}</template></el-table-column>
      <el-table-column label="缓存读取" width="120"><template #default="{ row }">{{ formatNumber(row.cached_tokens) }}</template></el-table-column>
      <el-table-column label="失败" width="80">
        <template #default="{ row }"><span :class="{ bad: row.failures }">{{ row.failures }}</span></template>
      </el-table-column>
    </el-table>
  </div>
</template>

<style scoped>
.stats { margin-bottom: 20px; }
.bad { color: var(--el-color-danger); }
</style>
