<script setup lang="ts">
import { onMounted, ref, watch } from 'vue'
import { ElMessage } from 'element-plus'
import { api, errorMessage } from '@/api/client'
import type { AINote, Bank } from '@/api/types'
import Markdown from '@/components/Markdown.vue'
import { formatTime } from '@/utils/format'

const PAGE_SIZE = 20

const banks = ref<Bank[]>([])
const bankId = ref('')
const search = ref('')
const page = ref(1)
const total = ref(0)
const items = ref<AINote[]>([])
const loading = ref(false)

async function load() {
  loading.value = true
  try {
    const r = await api.aiNotes({
      bank_id: bankId.value || undefined,
      search: search.value.trim() || undefined,
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
function refilter() {
  if (page.value === 1) void load()
  else page.value = 1
}

// Judge questions label their options 1/2, single choice A/B/C…
const label = (n: AINote, i: number) => (n.type === 'judge' ? String(i + 1) : String.fromCharCode(65 + i))
const labels = (n: AINote, idx: number[]) => idx.map((i) => label(n, i)).join('、') || '-'

onMounted(async () => {
  banks.value = await api.banks().catch(() => [])
  await load()
})
watch(page, load)
</script>

<template>
  <div>
    <div class="bar">
      <el-select v-model="bankId" clearable placeholder="全部题库" style="width: 200px" @change="refilter">
        <el-option v-for="b in banks" :key="b.id" :label="b.title" :value="b.id" />
      </el-select>
      <el-input v-model="search" clearable placeholder="搜索题干或解读内容" style="width: 260px"
        @keyup.enter="refilter" @clear="refilter" />
      <el-button @click="refilter">搜索</el-button>
      <span class="muted">共 {{ total }} 条</span>
    </div>

    <el-table :data="items" v-loading="loading" row-key="question_id" empty-text="还没有 AI 解读记录（App 里生成并同步后会出现在这里）">
      <el-table-column type="expand">
        <template #default="{ row }">
          <div class="detail">
            <h4>题目</h4>
            <div class="stem">{{ row.stem }}</div>
            <ul class="opts">
              <li v-for="(o, i) in row.options" :key="i" :class="{ right: row.answer.includes(i) }">
                <b>{{ label(row, i) }}.</b> {{ o }}
                <el-tag v-if="row.answer.includes(i)" size="small" type="success">正确答案</el-tag>
                <el-tag v-if="row.selected.includes(i)" size="small" type="warning">提问时所选</el-tag>
              </li>
            </ul>
            <div v-if="row.explanation" class="orig"><b>原解析：</b>{{ row.explanation }}</div>
            <h4>AI 解读</h4>
            <div class="content"><Markdown :source="row.content" /></div>
          </div>
        </template>
      </el-table-column>
      <el-table-column label="题目" min-width="320">
        <template #default="{ row }"><div class="clamp">{{ row.stem }}</div></template>
      </el-table-column>
      <el-table-column label="题库" prop="bank_title" width="160" show-overflow-tooltip />
      <el-table-column label="提问时所选" width="100">
        <template #default="{ row }">{{ labels(row, row.selected) }}</template>
      </el-table-column>
      <el-table-column label="模型" prop="model" width="160" show-overflow-tooltip />
      <el-table-column label="时间" width="120">
        <template #default="{ row }">{{ formatTime(row.updated_at) }}</template>
      </el-table-column>
    </el-table>

    <el-pagination v-if="total > PAGE_SIZE" v-model:current-page="page" class="pager" background
      layout="prev, pager, next" :page-size="PAGE_SIZE" :total="total" />
  </div>
</template>

<style scoped>
.bar { display: flex; gap: 10px; align-items: center; margin-bottom: 12px; flex-wrap: wrap; }
.clamp { display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; line-height: 1.5; }
.pager { margin-top: 14px; justify-content: flex-end; }
.detail { padding: 8px 16px 12px 48px; max-width: 860px; line-height: 1.7; }
.detail h4 { margin: 10px 0 6px; font-size: 13px; color: var(--el-text-color-secondary); }
.stem { white-space: pre-wrap; }
.opts { margin: 6px 0; padding: 0; list-style: none; }
.opts li { padding: 2px 0; }
.opts li.right { color: var(--el-color-success); }
.orig { margin-top: 6px; color: var(--el-text-color-secondary); white-space: pre-wrap; }
.content { padding: 10px 12px; border-radius: 8px; background: var(--el-fill-color-light); }
</style>
