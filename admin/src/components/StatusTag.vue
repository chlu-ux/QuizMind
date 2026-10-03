<script setup lang="ts">
import { computed } from 'vue'
import { DOCUMENT_STATUS_LABEL, JOB_STATUS_LABEL, QUESTION_STATUS_LABEL } from '@/utils/format'

const props = defineProps<{ kind: 'question' | 'document' | 'job'; status: string }>()

const label = computed(() => {
  const map = props.kind === 'question' ? QUESTION_STATUS_LABEL : props.kind === 'document' ? DOCUMENT_STATUS_LABEL : JOB_STATUS_LABEL
  return map[props.status] ?? props.status
})

const type = computed(() => {
  switch (props.status) {
    case 'published':
    case 'done':
      return 'success'
    case 'needs_review':
    case 'review':
    case 'pending':
      return 'warning'
    case 'rejected':
    case 'failed':
      return 'danger'
    case 'running':
    case 'generating':
    case 'chunking':
      return 'primary'
    default:
      return 'info'
  }
})
</script>

<template>
  <el-tag :type="type" size="small" effect="light">{{ label }}</el-tag>
</template>
