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

/** One report from an app; resolved_at is null while it is unhandled. */
export interface QuestionFlag {
  reason: 'wrong_answer' | 'ambiguous' | 'typo' | 'other'
  created_at: number
  resolved_at: number | null
}

export interface QuestionDetail extends Question {
  chunk_text: string
  heading_path: string
  document_id: string
  /** Newest first. flag_count can exceed the unresolved rows: counts from before reasons were recorded have none. */
  flags: QuestionFlag[]
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
  documents: number
  last_updated: number
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

export interface DocumentContent extends DocumentRow {
  content: string
}

export interface MediaView {
  id: string
  /** What to put in Markdown: `media:<id>`. */
  ref: string
  mime: string
  size: number
  width: number
  height: number
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

export interface AIConfig {
  enabled: boolean
  base_url: string
  model: string
  max_tokens: number
  temperature: number
  app_token: string
  api_key_set: boolean
  api_key_hint: string
}

/** What is sent when saving; an empty api_key keeps the stored key. */
export type AIConfigUpdate = Omit<AIConfig, 'api_key_set' | 'api_key_hint'> & { api_key: string }

export interface AITestResult {
  ok: boolean
  reply?: string
  error?: string
  latency_ms: number
}

export interface AINote {
  question_id: string
  bank_id: string
  bank_title: string
  type: Question['type']
  stem: string
  options: string[]
  answer: number[]
  explanation: string
  content: string
  model: string
  prompt_version: string
  selected: number[]
  device_id: string
  updated_at: number
}

export interface AINotePage {
  items: AINote[]
  total: number
}
