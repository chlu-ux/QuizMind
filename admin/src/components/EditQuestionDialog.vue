<script setup lang="ts">
import { reactive, ref, watch } from 'vue'
import { ElMessage } from 'element-plus'
import { api, errorMessage } from '@/api/client'
import type { QuestionDetail } from '@/api/types'
import { OPTION_LETTERS } from '@/utils/format'

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
        <el-input v-model="form.stem" type="textarea" :rows="3" maxlength="300" show-word-limit />
      </el-form-item>
      <el-form-item :label="question?.type === 'single' ? '选项（选中的是正确答案）' : '答案'">
        <el-radio-group v-model="form.answerIndex" class="opts">
          <template v-if="question?.type === 'single'">
            <div v-for="(_, i) in form.options" :key="i" class="opt">
              <el-radio :value="i"><b>{{ OPTION_LETTERS[i] }}</b></el-radio>
              <el-input v-model="form.options[i]" />
            </div>
          </template>
          <template v-else>
            <el-radio :value="0">正确</el-radio>
            <el-radio :value="1">错误</el-radio>
          </template>
        </el-radio-group>
      </el-form-item>
      <el-form-item label="解析"><el-input v-model="form.explanation" type="textarea" :rows="2" /></el-form-item>
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
.opt { display: flex; align-items: center; gap: 8px; }
</style>
