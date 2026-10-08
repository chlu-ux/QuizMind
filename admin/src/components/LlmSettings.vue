<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage, ElMessageBox } from 'element-plus'
import { api, errorMessage } from '@/api/client'
import type { LlmConfig, LlmModel, LlmProvider, LlmRole, Protocol } from '@/api/types'
import { formatNumber } from '@/utils/format'

const cfg = ref<LlmConfig>({ providers: [], models: [], roles: {}, limits: { max_concurrency: 2, rps: 2, daily_token_budget: 0 } })
const loading = ref(false)

async function load() {
  loading.value = true
  try {
    cfg.value = await api.llm()
    Object.assign(limits, cfg.value.limits)
  } catch (e) {
    ElMessage.error(errorMessage(e))
  } finally {
    loading.value = false
  }
}
onMounted(load)

const protocolLabel: Record<Protocol, string> = { anthropic: 'Anthropic', openai: 'OpenAI 兼容' }
const providerOf = (id: string) => cfg.value.providers.find((p) => p.id === id)
const protocolOf = (m: LlmModel) => providerOf(m.provider_id)?.protocol

// ---- providers ----

const providerDialog = ref(false)
const editingProvider = ref<LlmProvider | null>(null)
const providerForm = reactive({ name: '', protocol: 'anthropic' as Protocol, base_url: '', api_key: '' })
const savingProvider = ref(false)

function openProvider(p?: LlmProvider) {
  editingProvider.value = p ?? null
  Object.assign(providerForm, p
    ? { name: p.name, protocol: p.protocol, base_url: p.base_url, api_key: '' }
    : { name: '', protocol: 'anthropic', base_url: '', api_key: '' })
  providerDialog.value = true
}

async function saveProvider() {
  savingProvider.value = true
  try {
    if (editingProvider.value) await api.updateProvider(editingProvider.value.id, { ...providerForm })
    else await api.createProvider({ ...providerForm })
    providerDialog.value = false
    await load()
  } catch (e) {
    ElMessage.error(errorMessage(e))
  } finally {
    savingProvider.value = false
  }
}

async function removeProvider(p: LlmProvider) {
  try {
    await ElMessageBox.confirm(`删除供应商「${p.name}」？`, '确认', { type: 'warning' })
    await api.deleteProvider(p.id)
    await load()
  } catch (e) {
    if (e !== 'cancel') ElMessage.error(errorMessage(e))
  }
}

// ---- models ----

const modelDialog = ref(false)
const editingModel = ref<LlmModel | null>(null)
const modelForm = reactive({ provider_id: '', name: '', model: '', max_tokens: 8000, temperature: 0, effort: '', vision: false })
const savingModel = ref(false)
const formProtocol = computed(() => providerOf(modelForm.provider_id)?.protocol)

function openModel(m?: LlmModel) {
  if (!m && cfg.value.providers.length === 0) {
    ElMessage.warning('请先添加一个供应商')
    return
  }
  editingModel.value = m ?? null
  Object.assign(modelForm, m
    ? { provider_id: m.provider_id, name: m.name, model: m.model, max_tokens: m.max_tokens, temperature: m.temperature, effort: m.effort, vision: m.vision }
    : { provider_id: cfg.value.providers[0].id, name: '', model: '', max_tokens: 8000, temperature: 0, effort: '', vision: false })
  modelDialog.value = true
}

async function saveModel() {
  savingModel.value = true
  try {
    // Fields that do not apply to the protocol are not sent as values.
    const body = {
      ...modelForm,
      temperature: formProtocol.value === 'openai' ? modelForm.temperature : 0,
      effort: formProtocol.value === 'anthropic' ? modelForm.effort : '',
    }
    if (editingModel.value) await api.updateModel(editingModel.value.id, body)
    else await api.createModel(body)
    modelDialog.value = false
    await load()
  } catch (e) {
    ElMessage.error(errorMessage(e))
  } finally {
    savingModel.value = false
  }
}

async function removeModel(m: LlmModel) {
  try {
    await ElMessageBox.confirm(`删除模型「${m.name}」？`, '确认', { type: 'warning' })
    await api.deleteModel(m.id)
    await load()
  } catch (e) {
    if (e !== 'cancel') ElMessage.error(errorMessage(e))
  }
}

const testing = ref('')
async function testModel(m: LlmModel) {
  testing.value = m.id
  try {
    const r = await api.testModel(m.id)
    // A model bound to the assistant is also checked for streaming and tool use.
    const report = (r.checks ?? []).map((c) => `${c.name}${c.ok ? ' ✓' : ` ✗${c.detail ? `（${c.detail}）` : ''}`}`).join('；')
    const warn = (r.checks ?? []).some((c) => !c.ok)
    if (r.ok && !warn) ElMessage.success(`「${m.name}」连接成功（${r.latency_ms} ms）${report ? `。${report}` : `，回复：${r.reply}`}`)
    else if (r.ok) ElMessage({ type: 'warning', message: `「${m.name}」可用，但有提示：${report}`, duration: 10000, showClose: true })
    else ElMessage({ type: 'error', message: `「${m.name}」${r.checks?.length ? '' : '连接失败：'}${r.error}${report ? `。${report}` : ''}`, duration: 10000, showClose: true })
  } catch (e) {
    ElMessage.error(errorMessage(e))
  } finally {
    testing.value = ''
  }
}

// ---- roles ----

const roleRows: { role: LlmRole; label: string; hint: string; protocol?: Protocol }[] = [
  { role: 'generator', label: '出题', hint: '把讲义生成题目的模型。' },
  { role: 'validator', label: '复核', hint: '助手出题时，用它不看答案独立做一遍；答案和助手给的不一致的题会被拒绝。没有指定则不复核。' },
  { role: 'agent', label: '学习 / 出题助手', hint: '对话式助手，需要 Anthropic 协议（可以是兼容 Anthropic 接口的第三方）。', protocol: 'anthropic' },
  { role: 'explain', label: 'AI 解读', hint: 'App 里的「AI 解读」直接调用它，需要 OpenAI 兼容接口。启用与令牌在「AI 解读」页设置。', protocol: 'openai' },
]
const savingRoles = ref(false)

function modelsFor(protocol?: Protocol) {
  return cfg.value.models.filter((m) => !protocol || protocolOf(m) === protocol)
}
const modelLabel = (m: LlmModel) => `${providerOf(m.provider_id)?.name ?? '?'} / ${m.name}`

async function bindRole(role: LlmRole, id: string | undefined) {
  savingRoles.value = true
  try {
    const next = { ...cfg.value.roles }
    if (id) next[role] = id
    else delete next[role]
    cfg.value = await api.saveRoles(next)
    ElMessage.success('已保存')
  } catch (e) {
    ElMessage.error(errorMessage(e))
    await load()
  } finally {
    savingRoles.value = false
  }
}

// ---- limits ----

const limits = reactive({ max_concurrency: 2, rps: 2, daily_token_budget: 0 })
const savingLimits = ref(false)
async function saveLimits() {
  savingLimits.value = true
  try {
    cfg.value = await api.saveLimits({ ...limits })
    ElMessage.success('已保存')
  } catch (e) {
    ElMessage.error(errorMessage(e))
  } finally {
    savingLimits.value = false
  }
}
</script>

<template>
  <div v-loading="loading" class="wrap">
    <section>
      <div class="head">
        <h3>供应商</h3>
        <el-button type="primary" size="small" @click="openProvider()">添加供应商</el-button>
      </div>
      <p class="muted">一个供应商对应一个接口地址和一个 Key，下面的多个模型可以共用它。</p>
      <el-table :data="cfg.providers" empty-text="还没有供应商" size="small">
        <el-table-column prop="name" label="名称" min-width="140" />
        <el-table-column label="协议" width="120"><template #default="{ row }">{{ protocolLabel[row.protocol as Protocol] }}</template></el-table-column>
        <el-table-column label="接口地址" min-width="220">
          <template #default="{ row }">{{ row.base_url || '（官方默认）' }}</template>
        </el-table-column>
        <el-table-column label="Key" width="130"><template #default="{ row }">{{ row.api_key_hint || '未设置' }}</template></el-table-column>
        <el-table-column label="" width="130" align="right">
          <template #default="{ row }">
            <el-button link type="primary" @click="openProvider(row)">编辑</el-button>
            <el-button link type="danger" @click="removeProvider(row)">删除</el-button>
          </template>
        </el-table-column>
      </el-table>
    </section>

    <section>
      <div class="head">
        <h3>模型</h3>
        <el-button type="primary" size="small" @click="openModel()">添加模型</el-button>
      </div>
      <el-table :data="cfg.models" empty-text="还没有模型" size="small">
        <el-table-column prop="name" label="名称" min-width="140" />
        <el-table-column label="供应商" min-width="120"><template #default="{ row }">{{ providerOf(row.provider_id)?.name }}</template></el-table-column>
        <el-table-column prop="model" label="模型 ID" min-width="180" />
        <el-table-column label="最大输出" width="100"><template #default="{ row }">{{ formatNumber(row.max_tokens) }}</template></el-table-column>
        <el-table-column label="参数" width="140">
          <template #default="{ row }">
            <span v-if="protocolOf(row) === 'anthropic' && row.effort">effort {{ row.effort }}</span>
            <span v-else-if="protocolOf(row) === 'openai' && row.temperature">temp {{ row.temperature }}</span>
            <span v-else class="muted">默认</span>
            <el-tag v-if="row.vision" size="small" type="success" class="vision-tag">识图</el-tag>
          </template>
        </el-table-column>
        <el-table-column label="" width="190" align="right">
          <template #default="{ row }">
            <el-button link :loading="testing === row.id" @click="testModel(row)">测试</el-button>
            <el-button link type="primary" @click="openModel(row)">编辑</el-button>
            <el-button link type="danger" @click="removeModel(row)">删除</el-button>
          </template>
        </el-table-column>
      </el-table>
    </section>

    <section>
      <h3>角色</h3>
      <p class="muted">为每个用途选一个模型，修改后立即生效，不用重启服务。没有选择的用途不可用。</p>
      <el-form label-width="140px" class="roles">
        <el-form-item v-for="r in roleRows" :key="r.role" :label="r.label">
          <el-select :model-value="cfg.roles[r.role]" clearable placeholder="未指定" style="width: 320px" :disabled="savingRoles"
            @update:model-value="(v: string | undefined) => bindRole(r.role, v)">
            <el-option v-for="m in modelsFor(r.protocol)" :key="m.id" :value="m.id" :label="modelLabel(m)" />
          </el-select>
          <div class="hint">{{ r.hint }}</div>
        </el-form-item>
      </el-form>
    </section>

    <section>
      <h3>调用限额</h3>
      <p class="muted">对服务端自己发起的所有模型调用（出题、复核、助手）合计生效。</p>
      <el-form label-width="140px" class="roles">
        <el-form-item label="同时请求数"><el-input-number v-model="limits.max_concurrency" :min="1" :max="16" /></el-form-item>
        <el-form-item label="每秒请求数">
          <el-input-number v-model="limits.rps" :min="0" :max="100" :step="0.5" :precision="1" />
          <div class="hint">0 表示不限。</div>
        </el-form-item>
        <el-form-item label="每日 token 预算">
          <el-input-number v-model="limits.daily_token_budget" :min="0" :step="100000" />
          <div class="hint">用完后出题任务会顺延到次日；0 表示不限。</div>
        </el-form-item>
        <el-form-item><el-button type="primary" :loading="savingLimits" @click="saveLimits">保存限额</el-button></el-form-item>
      </el-form>
    </section>

    <el-dialog v-model="providerDialog" :title="editingProvider ? '编辑供应商' : '添加供应商'" width="520px">
      <el-form :model="providerForm" label-width="90px">
        <el-form-item label="名称"><el-input v-model="providerForm.name" placeholder="例如 Anthropic、DeepSeek" /></el-form-item>
        <el-form-item label="协议">
          <el-radio-group v-model="providerForm.protocol">
            <el-radio-button value="anthropic">Anthropic</el-radio-button>
            <el-radio-button value="openai">OpenAI 兼容</el-radio-button>
          </el-radio-group>
        </el-form-item>
        <el-form-item label="接口地址">
          <el-input v-model="providerForm.base_url"
            :placeholder="providerForm.protocol === 'openai' ? 'https://api.openai.com/v1' : '留空使用官方 https://api.anthropic.com'" />
          <div class="hint" v-if="providerForm.protocol === 'openai'">含版本段（通常是 /v1），后面会拼 /chat/completions。</div>
          <div class="hint" v-else>不含 /v1，后面会拼 /v1/messages。用兼容 Anthropic 接口的第三方时填它给的地址。</div>
        </el-form-item>
        <el-form-item label="API Key">
          <el-input v-model="providerForm.api_key" type="password" show-password autocomplete="off"
            :placeholder="editingProvider?.api_key_set ? `已设置（${editingProvider.api_key_hint}），留空则不修改` : 'sk-…'" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="providerDialog = false">取消</el-button>
        <el-button type="primary" :loading="savingProvider" @click="saveProvider">保存</el-button>
      </template>
    </el-dialog>

    <el-dialog v-model="modelDialog" :title="editingModel ? '编辑模型' : '添加模型'" width="520px">
      <el-form :model="modelForm" label-width="100px">
        <el-form-item label="供应商">
          <el-select v-model="modelForm.provider_id" style="width: 100%">
            <el-option v-for="p in cfg.providers" :key="p.id" :value="p.id" :label="`${p.name}（${protocolLabel[p.protocol]}）`" />
          </el-select>
        </el-form-item>
        <el-form-item label="模型 ID"><el-input v-model="modelForm.model" placeholder="claude-sonnet-5-5 / deepseek-chat / gpt-4o-mini …" /></el-form-item>
        <el-form-item label="显示名称"><el-input v-model="modelForm.name" placeholder="留空则同模型 ID" /></el-form-item>
        <el-form-item label="最大输出">
          <el-input-number v-model="modelForm.max_tokens" :min="16" :max="64000" :step="500" />
          <div class="hint">单次调用输出 token 的上限。</div>
        </el-form-item>
        <el-form-item v-if="formProtocol === 'openai'" label="Temperature">
          <el-input-number v-model="modelForm.temperature" :min="0" :max="2" :step="0.1" :precision="1" />
          <div class="hint">0 表示用供应商默认值。</div>
        </el-form-item>
        <el-form-item v-if="formProtocol === 'anthropic'" label="Effort">
          <el-select v-model="modelForm.effort" style="width: 160px">
            <el-option value="" label="模型默认" />
            <el-option v-for="e in ['low', 'medium', 'high', 'xhigh', 'max']" :key="e" :value="e" :label="e" />
          </el-select>
          <div class="hint">思考投入程度；第三方兼容接口可能不支持，留默认即可。</div>
        </el-form-item>
        <el-form-item label="支持识图">
          <el-switch v-model="modelForm.vision" />
          <div class="hint">打开后，绑定为“学习 / 出题助手”时，学习者可以给助手发图片。确认这个模型真的看得懂图片再打开；“测试”按钮不测图片。</div>
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="modelDialog = false">取消</el-button>
        <el-button type="primary" :loading="savingModel" @click="saveModel">保存</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<style scoped>
.wrap { max-width: 980px; }
section { margin-bottom: 32px; }
h3 { margin: 0; font-size: 16px; }
.head { display: flex; align-items: center; justify-content: space-between; margin-bottom: 4px; }
.muted { color: var(--el-text-color-secondary); font-size: 13px; margin: 4px 0 12px; }
.vision-tag { margin-left: 6px; }
.hint { font-size: 12px; color: var(--el-text-color-secondary); line-height: 1.5; margin-top: 4px; width: 100%; }
.roles { max-width: 720px; }
</style>
