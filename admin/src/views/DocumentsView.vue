<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import { ElMessage, ElMessageBox } from 'element-plus'
import { UploadFilled } from '@element-plus/icons-vue'
import type { UploadRequestOptions } from 'element-plus'
import { api, errorMessage } from '@/api/client'
import type { Bank, DocumentDetail, DocumentRow } from '@/api/types'
import StatusTag from '@/components/StatusTag.vue'
import { useEvents } from '@/stores/events'
import { debounce } from '@/utils/debounce'
import { formatTime } from '@/utils/format'

const route = useRoute()
const events = useEvents()

const banks = ref<Bank[]>([])
const docs = ref<DocumentRow[]>([])
const bankId = ref('')
const loading = ref(false)
const drawer = ref(false)
const detail = ref<DocumentDetail | null>(null)

const visibleDocs = computed(() => (bankId.value ? docs.value.filter((d) => d.bank_id === bankId.value) : docs.value))
const bankTitle = (id: string) => banks.value.find((b) => b.id === id)?.title ?? id

async function load() {
  loading.value = true
  try {
    ;[banks.value, docs.value] = await Promise.all([api.banks(), api.documents()])
    if (!bankId.value && banks.value.length) bankId.value = banks.value[0].id
    if (detail.value && drawer.value) detail.value = await api.document(detail.value.id)
  } catch (e) {
    ElMessage.error(errorMessage(e))
  } finally {
    loading.value = false
  }
}
const reload = debounce(load, 250)

async function createBank() {
  try {
    const { value } = await ElMessageBox.prompt('给题库起个名字', '新建题库', { confirmButtonText: '创建', cancelButtonText: '取消' })
    const b = await api.createBank(value, '')
    await load()
    bankId.value = b.id
  } catch (e) {
    if (e !== 'cancel' && e !== 'close') ElMessage.error(errorMessage(e))
  }
}

async function upload(opt: UploadRequestOptions) {
  if (!bankId.value) {
    ElMessage.warning('请先选择或新建题库')
    opt.onError(new Error('no bank') as never)
    return
  }
  try {
    const res = await api.upload(bankId.value, opt.file as File)
    if (res.unchanged) ElMessage.info(`「${res.document.source_path}」内容没有变化，已跳过`)
    else if (res.created) ElMessage.success(`已上传「${res.document.source_path}」，开始处理`)
    else ElMessage.success(`已更新「${res.document.source_path}」，只会重新处理改动的部分`)
    opt.onSuccess(res)
    await load()
  } catch (e) {
    ElMessage.error(`${(opt.file as File).name}：${errorMessage(e)}`)
    opt.onError(e as never)
  }
}

async function open(id: string) {
  try {
    detail.value = await api.document(id)
    drawer.value = true
  } catch (e) {
    ElMessage.error(errorMessage(e))
  }
}

async function retry(id: string) {
  try {
    const r = await api.retryDocument(id)
    ElMessage.success(r.requeued ? `已重新排队 ${r.requeued} 个任务` : '没有可重试的任务')
    await load()
  } catch (e) {
    ElMessage.error(errorMessage(e))
  }
}

const busy = (s: string) => s === 'chunking' || s === 'generating'

let off: (() => void) | undefined
onMounted(async () => {
  await load()
  off = events.on((e) => {
    if (e.type === 'document' || e.type === 'job') reload()
  })
  const openId = route.query.open as string | undefined
  if (openId) open(openId)
})
onBeforeUnmount(() => {
  off?.()
  reload.cancel()
})
</script>

<template>
  <div class="page">
    <div class="toolbar">
      <el-select v-model="bankId" placeholder="选择题库" style="width: 220px">
        <el-option v-for="b in banks" :key="b.id" :label="b.title" :value="b.id" />
      </el-select>
      <el-button @click="createBank">新建题库</el-button>
    </div>

    <el-upload drag multiple accept=".md,.markdown" :show-file-list="false" :http-request="upload" class="uploader">
      <el-icon class="el-icon--upload"><UploadFilled /></el-icon>
      <div class="el-upload__text">把 Markdown 文件拖到这里，或 <em>点击上传</em></div>
      <template #tip>
        <div class="el-upload__tip">
          上传到「{{ bankId ? bankTitle(bankId) : '（未选择题库）' }}」。同名文件再次上传会更新原文档，只重新处理改动的部分。
        </div>
      </template>
    </el-upload>

    <el-table :data="visibleDocs" v-loading="loading" style="margin-top: 20px" empty-text="还没有文档，先上传一个 Markdown 文件">
      <el-table-column label="文档" min-width="150">
        <template #default="{ row }">
          <div>{{ row.title }}</div>
          <div class="muted mono small">{{ row.source_path }}</div>
        </template>
      </el-table-column>
      <el-table-column label="状态" width="100">
        <template #default="{ row }">
          <StatusTag kind="document" :status="row.status" />
          <el-icon v-if="busy(row.status)" class="is-loading spin"><svg viewBox="0 0 1024 1024"><path fill="currentColor" d="M512 64a32 32 0 0 1 32 32v192a32 32 0 0 1-64 0V96a32 32 0 0 1 32-32zm0 640a32 32 0 0 1 32 32v192a32 32 0 1 1-64 0V736a32 32 0 0 1 32-32z" /></svg></el-icon>
        </template>
      </el-table-column>
      <el-table-column label="题目" min-width="170">
        <template #default="{ row }">
          <router-link :to="{ name: 'review', query: { document_id: row.id } }" class="counts">
            <span v-if="row.question_counts.needs_review" class="c warn">待审 {{ row.question_counts.needs_review }}</span>
            <span v-if="row.question_counts.published" class="c ok">已发布 {{ row.question_counts.published }}</span>
            <span v-if="row.question_counts.rejected" class="c bad">已驳回 {{ row.question_counts.rejected }}</span>
            <span v-if="row.question_counts.stale" class="c muted">过期 {{ row.question_counts.stale }}</span>
            <span v-if="row.question_counts.retired" class="c muted">下线 {{ row.question_counts.retired }}</span>
            <span v-if="!Object.keys(row.question_counts).length" class="muted">-</span>
          </router-link>
        </template>
      </el-table-column>
      <el-table-column label="更新" width="105"><template #default="{ row }">{{ formatTime(row.updated_at) }}</template></el-table-column>
      <el-table-column label="" width="150" align="right" fixed="right">
        <template #default="{ row }">
          <el-button v-if="row.status === 'failed'" size="small" type="warning" @click="retry(row.id)">重试</el-button>
          <el-button size="small" @click="open(row.id)">切块</el-button>
        </template>
      </el-table-column>
    </el-table>

    <el-drawer v-model="drawer" :title="detail?.title" size="560px">
      <template v-if="detail">
        <p class="muted">共 {{ detail.chunks.length }} 个切块。"已生成"表示这个块已经出过题（即使最后没有留下题目）。</p>
        <el-table :data="detail.chunks" size="small">
          <el-table-column prop="seq" label="#" width="50" />
          <el-table-column prop="heading_path" label="位置" min-width="180" show-overflow-tooltip />
          <el-table-column prop="chars" label="字数" width="70" />
          <el-table-column label="状态" width="100">
            <template #default="{ row }">
              <el-tag v-if="row.status !== 'active'" size="small" type="info">{{ row.status === 'stale' ? '已改动' : '已删除' }}</el-tag>
              <el-tag v-else-if="row.generated" size="small" type="success">已生成</el-tag>
              <el-tag v-else size="small" type="warning">待生成</el-tag>
            </template>
          </el-table-column>
        </el-table>
      </template>
    </el-drawer>
  </div>
</template>

<style scoped>
.uploader :deep(.el-upload-dragger) { padding: 24px; }
.small { font-size: 12px; }
.counts { display: flex; gap: 10px; flex-wrap: wrap; text-decoration: none; }
.c { font-size: 13px; }
.c.warn { color: var(--el-color-warning); }
.c.ok { color: var(--el-color-success); }
.c.bad { color: var(--el-color-danger); }
.spin { margin-left: 4px; vertical-align: middle; }
</style>
