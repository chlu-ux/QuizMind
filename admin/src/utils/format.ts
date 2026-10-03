export function formatTime(ms: number): string {
  if (!ms) return '-'
  const d = new Date(ms)
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getMonth() + 1}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`
}

export function formatNumber(n: number): string {
  return n.toLocaleString('en-US')
}

export const QUESTION_STATUS_LABEL: Record<string, string> = {
  draft: '草稿',
  validated: '已校验',
  needs_review: '待审核',
  rejected: '已驳回',
  published: '已发布',
  stale: '已过期',
  retired: '已下线',
}

export const DOCUMENT_STATUS_LABEL: Record<string, string> = {
  imported: '已导入',
  chunking: '切块中',
  generating: '生成中',
  review: '待审核',
  failed: '失败',
}

export const JOB_STATUS_LABEL: Record<string, string> = {
  pending: '排队中',
  running: '运行中',
  done: '完成',
  failed: '失败',
}

export const JOB_TYPE_LABEL: Record<string, string> = {
  chunk_document: '切块',
  generate_chunk: '生成题目',
}

export const TYPE_LABEL: Record<string, string> = {
  single: '单选',
  judge: '判断',
  multi: '多选',
  fill: '填空',
}

export const OPTION_LETTERS = ['A', 'B', 'C', 'D', 'E', 'F']
