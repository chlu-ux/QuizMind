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

// "flagged" overlaps the statuses, so the total below leaves it out.
const COLUMNS = [
  { status: 'published', label: '已发布', cls: 'ok' },
  { status: 'needs_review', label: '待审核', cls: 'warn' },
  { status: 'rejected', label: '已驳回', cls: '' },
  { status: 'stale', label: '过期', cls: '' },
  { status: 'retired', label: '下线', cls: '' },
]

/** Assistant drafts belong to their chat until accepted, so they are not part of the bank's question count. */
function total(bank: Bank): number {
  return Object.entries(bank.question_counts).reduce((n, [k, v]) => (k === 'flagged' || k === 'draft' ? n : n + v), 0)
}

function count(bank: Bank, status: string): number {
  return bank.question_counts[status] ?? 0
}

/** The review page lists a bank's questions; an empty status shows all of them. */
function listTo(bank: Bank, status: string) {
  return { name: 'review', query: { bank_id: bank.id, status } }
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
      <el-table-column label="题库" min-width="180">
        <template #default="{ row }">
          <router-link :to="listTo(row, '')">{{ row.title }}</router-link>
        </template>
      </el-table-column>
      <el-table-column label="全部" width="64">
        <template #default="{ row }">{{ total(row) }}</template>
      </el-table-column>
      <el-table-column v-for="c in COLUMNS" :key="c.status" :label="c.label" width="72">
        <template #default="{ row }">
          <router-link v-if="count(row, c.status)" :to="listTo(row, c.status)" :class="c.cls">{{ count(row, c.status) }}</router-link>
          <span v-else class="muted">0</span>
        </template>
      </el-table-column>
      <el-table-column label="被反馈" width="72">
        <template #default="{ row }">
          <router-link v-if="count(row, 'flagged')" :to="listTo(row, 'flagged')" class="bad">{{ count(row, 'flagged') }}</router-link>
          <span v-else class="muted">0</span>
        </template>
      </el-table-column>
      <el-table-column label="文档" width="64">
        <template #default="{ row }">
          <router-link :to="{ name: 'documents', query: { bank_id: row.id } }">{{ row.documents }}</router-link>
        </template>
      </el-table-column>
      <el-table-column label="最近更新" width="130"><template #default="{ row }">{{ formatTime(row.last_updated) }}</template></el-table-column>
      <el-table-column label="" width="88" align="right">
        <template #default="{ row }">
          <el-button size="small" link type="primary" @click="$router.push({ name: 'documents', query: { bank_id: row.id } })">上传文档</el-button>
        </template>
      </el-table-column>
    </el-table>
  </div>
</template>

<style scoped>
.ok { color: var(--el-color-success); }
.warn { color: var(--el-color-warning); }
.bad { color: var(--el-color-danger); }
</style>
