<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { ElMessage, ElMessageBox } from 'element-plus'
import { api, errorMessage } from '@/api/client'
import type { Bank, DocumentRow, Question, QuestionDetail } from '@/api/types'
import Markdown from '@/components/Markdown.vue'
import QuestionCard from '@/components/QuestionCard.vue'
import SourceExcerpt from '@/components/SourceExcerpt.vue'
import StatusTag from '@/components/StatusTag.vue'
import EditQuestionDialog from '@/components/EditQuestionDialog.vue'
import { FLAG_REASON_LABEL, QUESTION_STATUS_LABEL, TYPE_LABEL, formatTime } from '@/utils/format'
import { plainText } from '@/utils/media'
import { debounce } from '@/utils/debounce'

const route = useRoute()
const router = useRouter()

const PAGE = 50
// 'flagged' is not a status: it lists the questions with unresolved reports, whatever their status.
const FLAGGED = 'flagged'
const statuses = ['needs_review', FLAGGED, 'published', 'rejected', 'stale', 'retired', '']

const status = ref<string>((route.query.status as string) ?? 'needs_review')
const bankId = ref<string>((route.query.bank_id as string) ?? '')
const documentId = ref<string>((route.query.document_id as string) ?? '')
const search = ref<string>((route.query.search as string) ?? '')
// Where a question came from: the study assistant's questions can be reviewed on their own.
const source = ref<string>((route.query.source as string) ?? '')
const banks = ref<Bank[]>([])
const documents = ref<DocumentRow[]>([])

const items = ref<Question[]>([])
const total = ref(0)
const page = ref(1)
const loading = ref(false)
const selectedId = ref<string>('')
const detail = ref<QuestionDetail | null>(null)
const checked = ref<Set<string>>(new Set())
const editing = ref(false)
const flaggedCount = ref(0)

const docOptions = computed(() => (bankId.value ? documents.value.filter((d) => d.bank_id === bankId.value) : documents.value))
const selectedIndex = computed(() => items.value.findIndex((q) => q.id === selectedId.value))
const allChecked = computed(() => items.value.length > 0 && items.value.every((q) => checked.value.has(q.id)))
const canApprove = computed(() => !!detail.value && ['needs_review', 'validated', 'rejected', 'draft'].includes(detail.value.status))
const canReject = computed(() => !!detail.value && ['needs_review', 'validated', 'published', 'draft'].includes(detail.value.status))
const canEdit = computed(() => !!detail.value && !['stale', 'retired'].includes(detail.value.status))
const canDismiss = computed(() => !!detail.value && detail.value.flag_count > 0)

const openFlags = computed(() => (detail.value?.flags ?? []).filter((f) => f.resolved_at === null))
/** "答案不对 ×2、题干有歧义 ×1" */
const flagSummary = computed(() => {
  const n: Record<string, number> = {}
  for (const f of openFlags.value) n[f.reason] = (n[f.reason] ?? 0) + 1
  return Object.entries(n).map(([r, c]) => `${FLAG_REASON_LABEL[r] ?? r} ×${c}`).join('、')
})
const flagsWithoutDetail = computed(() => Math.max(0, (detail.value?.flag_count ?? 0) - openFlags.value.length))

function statusLabel(s: string): string {
  if (s === FLAGGED) return flaggedCount.value ? `被反馈（${flaggedCount.value}）` : '被反馈'
  return s ? QUESTION_STATUS_LABEL[s] : '全部状态'
}

/** Does the question still belong in the list under the current status filter? */
function matchesFilter(q: Question): boolean {
  if (status.value === FLAGGED) return q.flag_count > 0
  return !status.value || q.status === status.value
}

async function loadFlaggedCount() {
  try {
    const bs = await api.banks()
    flaggedCount.value = bs.reduce((n, b) => n + (b.question_counts.flagged ?? 0), 0)
  } catch {
    /* the badge is a convenience */
  }
}

async function load(keepSelection = true) {
  loading.value = true
  try {
    const res = await api.questions({
      status: status.value && status.value !== FLAGGED ? status.value : undefined,
      flagged: status.value === FLAGGED ? 1 : undefined,
      source: source.value === 'agent' ? 'agent' : undefined,
      bank_id: bankId.value || undefined,
      document_id: documentId.value || undefined,
      search: search.value.trim() || undefined,
      limit: PAGE,
      offset: (page.value - 1) * PAGE,
    })
    items.value = res.items
    total.value = res.total
    checked.value = new Set([...checked.value].filter((id) => res.items.some((q) => q.id === id)))
    const stillThere = keepSelection && res.items.some((q) => q.id === selectedId.value)
    if (!stillThere) selectedId.value = res.items[0]?.id ?? ''
  } catch (e) {
    ElMessage.error(errorMessage(e))
  } finally {
    loading.value = false
  }
}

async function loadDetail() {
  if (!selectedId.value) {
    detail.value = null
    return
  }
  const id = selectedId.value
  try {
    const d = await api.question(id)
    if (id === selectedId.value) detail.value = d // ignore stale responses
  } catch (e) {
    ElMessage.error(errorMessage(e))
  }
}

watch(selectedId, loadDetail)
watch([status, bankId, documentId, source], () => {
  page.value = 1
  syncQuery()
  load(false)
})
// Typing fires on every keystroke; wait for a pause before querying.
const searchLater = debounce(() => {
  page.value = 1
  syncQuery()
  load(false)
}, 300)
watch(search, searchLater)
watch(bankId, () => {
  if (documentId.value && !docOptions.value.some((d) => d.id === documentId.value)) documentId.value = ''
})

function syncQuery() {
  router.replace({
    query: {
      ...(status.value !== 'needs_review' ? { status: status.value } : {}),
      ...(bankId.value ? { bank_id: bankId.value } : {}),
      ...(documentId.value ? { document_id: documentId.value } : {}),
      ...(source.value ? { source: source.value } : {}),
      ...(search.value.trim() ? { search: search.value.trim() } : {}),
    },
  })
}

/** After a decision: drop the row if it no longer matches the filter, then move on. */
function afterDecision(updated: Question) {
  const idx = items.value.findIndex((q) => q.id === updated.id)
  if (idx < 0) return
  if (!matchesFilter(updated)) {
    items.value.splice(idx, 1)
    total.value = Math.max(0, total.value - 1)
    checked.value.delete(updated.id)
    selectedId.value = items.value[Math.min(idx, items.value.length - 1)]?.id ?? ''
    if (items.value.length === 0 && total.value > 0) load(false)
  } else {
    items.value[idx] = updated
    if (selectedId.value === updated.id) loadDetail()
    if (idx + 1 < items.value.length) selectedId.value = items.value[idx + 1].id
  }
}

async function approve() {
  if (!detail.value || !canApprove.value) return
  try {
    afterDecision(await api.approve(detail.value.id))
    ElMessage.success('已通过并发布')
    loadFlaggedCount()
  } catch (e) {
    ElMessage.error(errorMessage(e))
  }
}

async function reject() {
  if (!detail.value || !canReject.value) return
  try {
    const { value } = await ElMessageBox.prompt('可选：写下驳回原因，方便以后调整提示词。', '驳回这道题', {
      confirmButtonText: '驳回',
      cancelButtonText: '取消',
      inputPlaceholder: '例如：题干有歧义',
    })
    afterDecision(await api.reject(detail.value.id, value ?? ''))
    ElMessage.success('已驳回')
    loadFlaggedCount()
  } catch (e) {
    if (e !== 'cancel' && e !== 'close') ElMessage.error(errorMessage(e))
  }
}

async function dismissFlags() {
  if (!detail.value || !canDismiss.value) return
  try {
    const wasOffline = detail.value.status === 'needs_review' && detail.value.review_note === 'flagged by app users'
    afterDecision(await api.dismissFlags(detail.value.id))
    ElMessage.success(wasOffline ? '已处理，题目重新上线' : '已处理，反馈已清零')
    loadFlaggedCount()
  } catch (e) {
    ElMessage.error(errorMessage(e))
  }
}

async function bulk(action: 'approve' | 'reject') {
  const ids = [...checked.value]
  if (!ids.length) return
  try {
    if (action === 'reject') {
      await ElMessageBox.confirm(`驳回选中的 ${ids.length} 道题？`, '批量驳回', { type: 'warning' })
    }
    const res = await api.bulk(action, ids, action === 'reject' ? '批量驳回' : '')
    const failed = Object.keys(res.failed).length
    if (failed) ElMessage.warning(`成功 ${res.done} 道，失败 ${failed} 道：${Object.values(res.failed)[0]}`)
    else ElMessage.success(`已处理 ${res.done} 道题`)
    checked.value = new Set()
    await load(false)
    loadFlaggedCount()
  } catch (e) {
    if (e !== 'cancel' && e !== 'close') ElMessage.error(errorMessage(e))
  }
}

function toggleAll(v: boolean | string | number) {
  checked.value = v ? new Set(items.value.map((q) => q.id)) : new Set()
}
function toggle(id: string, v: boolean | string | number) {
  const s = new Set(checked.value)
  if (v) s.add(id)
  else s.delete(id)
  checked.value = s
}

function move(delta: number) {
  const i = selectedIndex.value + delta
  if (i >= 0 && i < items.value.length) selectedId.value = items.value[i].id
}

function onSaved(q: QuestionDetail) {
  detail.value = q
  const idx = items.value.findIndex((x) => x.id === q.id)
  if (idx >= 0) items.value[idx] = { ...items.value[idx], ...q }
}

/** A dialog or message box is on screen (closed dialogs keep a hidden overlay in the DOM). */
function modalOpen(): boolean {
  return [...document.querySelectorAll('.el-overlay')].some((el) => getComputedStyle(el).display !== 'none')
}

function onKey(e: KeyboardEvent) {
  const el = e.target as HTMLElement | null
  if (e.metaKey || e.ctrlKey || e.altKey) return
  if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable)) return
  if (editing.value || modalOpen()) return
  switch (e.key) {
    case 'j':
    case 'ArrowDown':
      e.preventDefault()
      return move(1)
    case 'k':
    case 'ArrowUp':
      e.preventDefault()
      return move(-1)
    case 'a':
      return void approve()
    case 'r':
      e.preventDefault()
      return void reject()
    case 'd':
      return void dismissFlags()
    case 'e':
      if (canEdit.value) {
        e.preventDefault()
        editing.value = true
      }
  }
}

onMounted(async () => {
  window.addEventListener('keydown', onKey)
  const [b, d] = await Promise.all([api.banks(), api.documents()]).catch(() => [[], []] as [Bank[], DocumentRow[]])
  banks.value = b
  documents.value = d
  flaggedCount.value = b.reduce((n, x) => n + (x.question_counts.flagged ?? 0), 0)
  await load(false)
})
onBeforeUnmount(() => {
  window.removeEventListener('keydown', onKey)
  searchLater.cancel()
})
</script>

<template>
  <div class="review">
    <div class="filters">
      <el-select v-model="status" placeholder="全部状态" style="width: 150px">
        <el-option v-for="s in statuses" :key="s" :label="statusLabel(s)" :value="s" />
      </el-select>
      <el-select v-model="bankId" clearable placeholder="全部题库" style="width: 180px">
        <el-option v-for="b in banks" :key="b.id" :label="b.title" :value="b.id" />
      </el-select>
      <el-select v-model="documentId" clearable placeholder="全部文档" style="width: 200px">
        <el-option v-for="d in docOptions" :key="d.id" :label="d.title" :value="d.id" />
      </el-select>
      <el-select v-model="source" clearable placeholder="全部来源" style="width: 130px">
        <el-option label="来源：助手" value="agent" />
      </el-select>
      <el-input v-model="search" clearable placeholder="搜索题干、选项、解析" style="width: 220px" />
      <span class="muted">共 {{ total }} 道</span>
      <span class="grow" />
      <span class="muted keys">快捷键：<kbd>J</kbd>/<kbd>K</kbd> 切换 · <kbd>A</kbd> 通过 · <kbd>R</kbd> 驳回 · <kbd>E</kbd> 编辑 · <kbd>D</kbd> 处理完毕</span>
    </div>

    <div class="split">
      <div class="list" v-loading="loading">
        <div v-if="items.length" class="list-head">
          <el-checkbox :model-value="allChecked" @change="toggleAll">全选</el-checkbox>
          <template v-if="checked.size">
            <el-button size="small" type="primary" @click="bulk('approve')">通过 {{ checked.size }} 道</el-button>
            <el-button size="small" @click="bulk('reject')">驳回</el-button>
          </template>
        </div>
        <div
          v-for="q in items"
          :key="q.id"
          class="row"
          :class="{ active: q.id === selectedId }"
          @click="selectedId = q.id"
        >
          <el-checkbox :model-value="checked.has(q.id)" @click.stop @change="(v: boolean | string | number) => toggle(q.id, v)" />
          <div class="row-main">
            <div class="row-stem">{{ plainText(q.stem) }}</div>
            <div class="row-meta">
              <el-tag size="small" effect="plain">{{ TYPE_LABEL[q.type] ?? q.type }}</el-tag>
              <StatusTag kind="question" :status="q.status" />
              <span v-if="q.review_note.startsWith('auto:')" class="auto">自动</span>
              <span v-if="q.flag_count > 0" class="flagged">反馈 {{ q.flag_count }}</span>
            </div>
          </div>
        </div>
        <el-empty v-if="!items.length && !loading" description="没有符合条件的题目" />
        <el-pagination
          v-if="total > PAGE"
          v-model:current-page="page"
          :page-size="PAGE"
          :total="total"
          layout="prev, pager, next"
          small
          class="pager"
          @current-change="load(false)"
        />
      </div>

      <div class="detail">
        <template v-if="detail">
          <div class="actions">
            <el-button type="success" :disabled="!canApprove" @click="approve">通过 <kbd>A</kbd></el-button>
            <el-button type="danger" plain :disabled="!canReject" @click="reject">驳回 <kbd>R</kbd></el-button>
            <el-button :disabled="!canEdit" @click="editing = true">编辑 <kbd>E</kbd></el-button>
            <el-button v-if="canDismiss" type="primary" plain @click="dismissFlags">处理完毕（保留）<kbd>D</kbd></el-button>
            <span class="grow" />
            <StatusTag kind="question" :status="detail.status" />
          </div>

          <el-alert
            v-if="detail.flag_count > 0"
            type="error"
            :closable="false"
            show-icon
            class="flag-alert"
            :title="`${detail.flag_count} 位用户反馈了这道题${flagSummary ? '：' + flagSummary : ''}`"
          >
            <div v-if="flagsWithoutDetail" class="flag-line">共 {{ detail.flag_count }} 次反馈（其中 {{ flagsWithoutDetail }} 次无详细记录）</div>
            <div v-for="(f, i) in openFlags" :key="i" class="flag-line">
              {{ FLAG_REASON_LABEL[f.reason] ?? f.reason }} · {{ formatTime(f.created_at) }}
            </div>
            <div class="flag-line muted">“处理完毕”会清掉这些反馈；被反馈下线的题会重新上线。</div>
          </el-alert>

          <el-alert
            v-if="detail.review_note"
            :type="detail.review_note.startsWith('auto:') ? 'warning' : 'info'"
            :closable="false"
            show-icon
            :title="detail.review_note.startsWith('auto:') ? '自动校验未通过' : '审核备注'"
            :description="detail.review_note.replace(/^auto:\s*/, '')"
            style="margin-bottom: 12px"
          />

          <QuestionCard :q="detail" />
          <div v-if="detail.explanation" class="expl"><b>解析：</b><Markdown :source="detail.explanation" /></div>

          <h4>原文依据 <span class="muted path">{{ detail.heading_path }}</span></h4>
          <SourceExcerpt :text="detail.chunk_text" :quote="detail.source_quote" />

          <div class="foot muted">
            {{ detail.gen_model }} · {{ detail.gen_prompt_version }}
            <template v-if="detail.sync_seq !== null"> · sync #{{ detail.sync_seq }}</template>
            <router-link v-if="detail.document_id" :to="{ name: 'documents', query: { open: detail.document_id } }"> · 查看文档</router-link>
          </div>
        </template>
        <el-empty v-else description="选择左侧的一道题" />
      </div>
    </div>

    <EditQuestionDialog v-model="editing" :question="detail" @saved="onSaved" />
  </div>
</template>

<style scoped>
.review { display: flex; flex-direction: column; height: 100%; }
.filters { display: flex; gap: 10px; align-items: center; padding: 12px 20px; border-bottom: 1px solid var(--el-border-color); flex-wrap: wrap; }
.grow { flex: 1; }
.keys kbd, .actions kbd { font-size: 11px; padding: 0 4px; border: 1px solid var(--el-border-color); border-radius: 3px; margin-left: 3px; }
.split { flex: 1; display: grid; grid-template-columns: 380px 1fr; min-height: 0; }
.list { border-right: 1px solid var(--el-border-color); overflow: auto; }
.list-head { display: flex; gap: 8px; align-items: center; padding: 8px 12px; position: sticky; top: 0; background: var(--el-bg-color); border-bottom: 1px solid var(--el-border-color-lighter); z-index: 1; }
.row { display: flex; gap: 8px; padding: 10px 12px; border-bottom: 1px solid var(--el-border-color-lighter); cursor: pointer; }
.row:hover { background: var(--el-fill-color-light); }
.row.active { background: var(--el-color-primary-light-9); }
.row-main { min-width: 0; flex: 1; }
.row-stem { display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; line-height: 1.5; }
.row-meta { display: flex; gap: 6px; align-items: center; margin-top: 6px; }
.auto { font-size: 11px; color: var(--el-color-warning); }
.flagged { font-size: 11px; color: var(--el-color-danger); border: 1px solid var(--el-color-danger-light-5); border-radius: 3px; padding: 0 4px; }
.flag-alert { margin-bottom: 12px; }
.flag-line { font-size: 12px; line-height: 1.7; }
.pager { padding: 10px; justify-content: center; }
.detail { padding: 16px 24px; overflow: auto; }
.actions { display: flex; gap: 8px; align-items: center; margin-bottom: 14px; }
.expl { margin-top: 12px; line-height: 1.6; color: var(--el-text-color-regular); }
h4 { margin: 18px 0 8px; }
.path { font-weight: 400; font-size: 12px; margin-left: 8px; }
.foot { margin-top: 14px; font-size: 12px; }
</style>
