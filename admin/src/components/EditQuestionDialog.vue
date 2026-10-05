<script setup lang="ts">
import { reactive, ref, watch } from 'vue'
import { ElMessage } from 'element-plus'
import { api, errorMessage } from '@/api/client'
import type { QuestionDetail } from '@/api/types'
import Markdown from '@/components/Markdown.vue'
import MediaButton from '@/components/MediaButton.vue'
import OptText from '@/components/OptText.vue'
import { OPTION_LETTERS } from '@/utils/format'
import { segments } from '@/utils/media'

const props = defineProps<{ modelValue: boolean; question: QuestionDetail | null }>()
const emit = defineEmits<{ (e: 'update:modelValue', v: boolean): void; (e: 'saved', q: QuestionDetail): void }>()

const form = reactive({
  stem: '',
  options: [] as string[],
  answerIndex: 0,
  explanation: '',
  difficulty: 3,
  tags: [] as string[],
})
const saving = ref(false)
const stemPic = ref<InstanceType<typeof MediaButton>>()
const explPic = ref<InstanceType<typeof MediaButton>>()
const optPics = ref<InstanceType<typeof MediaButton>[]>([])

const hasPicture = (text: string) => segments(text).some((p) => p.kind === 'image')

const picture = (ref: string) => `![](${ref})`

/** A picture goes on its own line in a stem or explanation, and straight into an option. */
const block = (text: string, ref: string) => `${text}${text && !text.endsWith('\n') ? '\n\n' : ''}${picture(ref)}`

/** Pasting a screenshot into a field uploads it and adds it there. */
function onPaste(e: ClipboardEvent, target: InstanceType<typeof MediaButton> | undefined) {
  const file = [...(e.clipboardData?.files ?? [])].find((f) => f.type.startsWith('image/'))
  if (!file || !target) return
  e.preventDefault()
  void target.send(file)
}

watch(
  () => [props.modelValue, props.question] as const,
  ([open, q]) => {
    if (!open || !q) return
    form.stem = q.stem
    form.options = [...q.options]
    form.answerIndex = q.answer[0] ?? 0
    form.explanation = q.explanation
    form.difficulty = q.difficulty
    form.tags = [...q.tags]
  },
  { immediate: true },
)

async function save() {
  if (!props.question) return
  saving.value = true
  try {
    const edit = {
      stem: form.stem,
      answer_index: form.answerIndex,
      explanation: form.explanation,
      difficulty: form.difficulty,
      tags: form.tags,
      // Judge questions always use the fixed 正确 / 错误 options.
      ...(props.question.type === 'single' ? { options: form.options } : {}),
    }
    const updated = await api.editQuestion(props.question.id, edit)
    ElMessage.success('已保存')
    emit('saved', updated)
    emit('update:modelValue', false)
  } catch (e) {
    ElMessage.error(errorMessage(e))
  } finally {
    saving.value = false
  }
}
</script>

<template>
  <el-dialog :model-value="modelValue" title="编辑题目" width="640px" @update:model-value="emit('update:modelValue', $event)">
    <el-form label-position="top" @submit.prevent>
      <el-form-item label="题干">
        <div class="field">
          <el-input
            v-model="form.stem"
            type="textarea"
            :rows="3"
            maxlength="300"
            show-word-limit
            @paste="onPaste($event, stemPic)"
          />
          <div class="tools">
            <MediaButton ref="stemPic" @inserted="form.stem = block(form.stem, $event)" />
            <span class="hint">UML 图、流程图等可上传或直接粘贴截图</span>
          </div>
          <Markdown v-if="hasPicture(form.stem)" class="preview" :source="form.stem" />
        </div>
      </el-form-item>
      <el-form-item :label="question?.type === 'single' ? '选项（选中的是正确答案）' : '答案'">
        <el-radio-group v-model="form.answerIndex" class="opts">
          <template v-if="question?.type === 'single'">
            <div v-for="(_, i) in form.options" :key="i" class="opt">
              <el-radio :value="i"><b>{{ OPTION_LETTERS[i] }}</b></el-radio>
              <div class="field">
                <div class="inline">
                  <el-input v-model="form.options[i]" @paste="onPaste($event, optPics[i])" />
                  <MediaButton :ref="(el) => (optPics[i] = el as InstanceType<typeof MediaButton>)" @inserted="form.options[i] += picture($event)" />
                </div>
                <OptText v-if="hasPicture(form.options[i])" class="preview" :text="form.options[i]" />
              </div>
            </div>
          </template>
          <template v-else>
            <el-radio :value="0">正确</el-radio>
            <el-radio :value="1">错误</el-radio>
          </template>
        </el-radio-group>
      </el-form-item>
      <el-form-item label="解析">
        <div class="field">
          <el-input v-model="form.explanation" type="textarea" :rows="2" @paste="onPaste($event, explPic)" />
          <div class="tools"><MediaButton ref="explPic" @inserted="form.explanation = block(form.explanation, $event)" /></div>
          <Markdown v-if="hasPicture(form.explanation)" class="preview" :source="form.explanation" />
        </div>
      </el-form-item>
      <el-form-item label="难度"><el-rate v-model="form.difficulty" :max="5" /></el-form-item>
      <el-form-item label="标签（最多 3 个）">
        <el-select v-model="form.tags" multiple filterable allow-create default-first-option :multiple-limit="3" style="width: 100%" />
      </el-form-item>
      <el-alert
        v-if="question?.status === 'published'"
        type="info"
        :closable="false"
        show-icon
        title="这道题已发布，保存后客户端会同步到新内容。"
      />
    </el-form>
    <template #footer>
      <el-button @click="emit('update:modelValue', false)">取消</el-button>
      <el-button type="primary" :loading="saving" @click="save">保存</el-button>
    </template>
  </el-dialog>
</template>

<style scoped>
.opts { display: flex; flex-direction: column; align-items: stretch; width: 100%; gap: 8px; }
.opt { display: flex; align-items: flex-start; gap: 8px; }
.opt :deep(.el-radio) { margin-top: 4px; }
.field { flex: 1; min-width: 0; width: 100%; display: flex; flex-direction: column; gap: 6px; }
.inline { display: flex; gap: 6px; align-items: center; }
.tools { display: flex; align-items: center; gap: 10px; }
.hint { color: var(--el-text-color-secondary); font-size: 12px; }
.preview { padding: 8px 10px; border: 1px dashed var(--el-border-color); border-radius: 4px; }
</style>
