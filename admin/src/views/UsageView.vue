<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { api, errorMessage } from '@/api/client'
import type { UsageRow } from '@/api/types'
import UsageCalls from '@/components/UsageCalls.vue'
import { formatNumber } from '@/utils/format'
import { ROLE_LABEL, SOURCE_LABEL, cacheRate, filterRows, todayAndMonth, totalsOf } from '@/utils/usage'

// Loaded once for the longest range; the range and filters narrow it locally.
const HISTORY_DAYS = 90

const tab = ref('summary')
const days = ref(30)
const source = ref('')
const role = ref('')
const allRows = ref<UsageRow[]>([])
const loading = ref(false)

const now = new Date()
const sourceRows = computed(() => filterRows(allRows.value, { days: 0, source: source.value, role: role.value }, now))
const rows = computed(() => filterRows(allRows.value, { days: days.value, source: source.value, role: role.value }, now))
const totals = computed(() => totalsOf(rows.value))
const rate = computed(() => cacheRate(totals.value))
const spent = computed(() => todayAndMonth(sourceRows.value, now))

async function load() {
  loading.value = true
  try {
    allRows.value = await api.usage(HISTORY_DAYS)
  } catch (e) {
    ElMessage.error(errorMessage(e))
  } finally {
    loading.value = false
  }
}

onMounted(load)
</script>

<template>
  <div class="page">
    <div class="toolbar">
      <el-select v-model="days" style="width: 130px">
        <el-option :value="7" label="最近 7 天" />
        <el-option :value="30" label="最近 30 天" />
        <el-option :value="90" label="最近 90 天" />
      </el-select>
      <el-select v-model="source" clearable placeholder="全部来源" style="width: 130px">
        <el-option v-for="(label, k) in SOURCE_LABEL" :key="k" :value="k" :label="label" />
      </el-select>
      <el-select v-model="role" clearable placeholder="全部角色" style="width: 130px">
        <el-option v-for="(label, k) in ROLE_LABEL" :key="k" :value="k" :label="label" />
      </el-select>
      <span class="muted">只统计 token 数；单价请对照模型的价格表自行换算。每日预算只计服务端的调用。</span>
    </div>

    <el-row :gutter="12" class="stats">
      <el-col :span="4"><el-statistic title="今日 token" :value="spent.today" /></el-col>
      <el-col :span="4"><el-statistic title="本月 token" :value="spent.month" /></el-col>
      <el-col :span="4"><el-statistic title="调用次数" :value="totals.calls" /></el-col>
      <el-col :span="4"><el-statistic title="输入 token" :value="totals.input" /></el-col>
      <el-col :span="4"><el-statistic title="输出 token" :value="totals.output" /></el-col>
      <el-col :span="4"><el-statistic title="缓存命中" :value="rate" suffix="%" /></el-col>
    </el-row>

    <el-tabs v-model="tab">
      <el-tab-pane label="按天汇总" name="summary">
        <el-table :data="rows" v-loading="loading" empty-text="这段时间没有调用记录">
          <el-table-column prop="day" label="日期" width="120" />
          <el-table-column label="来源" width="90"><template #default="{ row }">{{ SOURCE_LABEL[row.source] ?? row.source }}</template></el-table-column>
          <el-table-column label="角色" width="100"><template #default="{ row }">{{ ROLE_LABEL[row.role] ?? row.role }}</template></el-table-column>
          <el-table-column prop="model" label="模型" min-width="180" />
          <el-table-column label="调用" width="110">
            <template #default="{ row }">
              {{ row.calls }}
              <el-tooltip v-if="row.estimated_calls" :content="`其中 ${row.estimated_calls} 次的 token 数是 App 估算的`">
                <el-tag size="small" type="info">估</el-tag>
              </el-tooltip>
            </template>
          </el-table-column>
          <el-table-column label="输入" width="110"><template #default="{ row }">{{ formatNumber(row.input_tokens) }}</template></el-table-column>
          <el-table-column label="输出" width="110"><template #default="{ row }">{{ formatNumber(row.output_tokens) }}</template></el-table-column>
          <el-table-column label="缓存读取" width="110"><template #default="{ row }">{{ formatNumber(row.cached_tokens) }}</template></el-table-column>
          <el-table-column label="失败" width="70">
            <template #default="{ row }"><span :class="{ bad: row.failures }">{{ row.failures }}</span></template>
          </el-table-column>
        </el-table>
      </el-tab-pane>
      <el-tab-pane label="调用明细" name="calls" lazy>
        <UsageCalls :days="days" :source="source" :role="role" />
      </el-tab-pane>
    </el-tabs>
  </div>
</template>

<style scoped>
.stats { margin-bottom: 20px; }
.bad { color: var(--el-color-danger); }
.toolbar { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.muted { color: var(--el-text-color-secondary); font-size: 13px; }
</style>
