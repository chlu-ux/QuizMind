// Mirrors the JSON returned by the Go server (internal/service views).

export type QuestionStatus =
  | 'draft' | 'validated' | 'needs_review' | 'rejected' | 'published' | 'stale' | 'retired'

export type DocumentStatus = 'imported' | 'chunking' | 'generating' | 'review' | 'failed'
export type JobStatus = 'pending' | 'running' | 'done' | 'failed'

export interface Question {
  id: string
  bank_id: string
  chunk_id: string
  type: 'single' | 'judge' | 'multi' | 'fill'
  stem: string
  options: string[]
  answer: number[]
  explanation: string
  difficulty: number
  tags: string[]
  source_quote: string
  status: QuestionStatus
  review_note: string
  gen_model: string
  gen_prompt_version: string
  flag_count: number
  sync_seq: number | null
  created_at: number
  updated_at: number
}

export interface QuestionDetail extends Question {
  chunk_text: string
  heading_path: string
  document_id: string
}

export interface QuestionPage {
  items: Question[]
  total: number
}

export interface QuestionEdit {
  stem?: string
  options?: string[]
  answer_index?: number
  explanation?: string
  difficulty?: number
  tags?: string[]
}

export type Counts = Record<string, number>

export interface Bank {
  id: string
  title: string
  description: string
  created_at: number
  question_counts: Counts
}

export interface DocumentRow {
  id: string
  bank_id: string
  title: string
  source_path: string
  status: DocumentStatus
  created_at: number
  updated_at: number
  question_counts: Counts
}

export interface ChunkRow {
  id: string
  seq: number
  heading_path: string
  status: 'active' | 'stale' | 'removed'
  generated: boolean
  chars: number
}

export interface DocumentDetail extends DocumentRow {
  chunks: ChunkRow[]
}

export interface ImportResult {
  document: DocumentRow
  created: boolean
  unchanged: boolean
}

export interface Job {
  id: string
  type: string
  document_id: string
  status: JobStatus
  attempts: number
  max_attempts: number
  last_error: string
  run_at: number
  created_at: number
  updated_at: number
}

export interface UsageRow {
  day: string
  model: string
  calls: number
  input_tokens: number
  output_tokens: number
  cached_tokens: number
  failures: number
}

export interface BulkResult {
  done: number
  failed: Record<string, string>
}

export interface ServerEvent {
  type: 'job' | 'document'
  id: string
  document_id?: string
  status: string
  kind?: string
  error?: string
}
