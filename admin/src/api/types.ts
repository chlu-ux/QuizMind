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

/** Where a question written by the study assistant came from. */
export interface AgentSource {
  conversation_id: string
  /** A second model answered it independently and agreed. */
  verified: boolean
}

export interface QuestionDetail extends Question {
  /** Set for questions the study assistant wrote, whatever their status now. */
  agent: AgentSource | null
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

export type UsageSource = 'server' | 'client'

export interface UsageRow {
  day: string
  /** Who made the calls: the server itself, or an app (AI explanations). */
  source: UsageSource
  role: LlmRole
  model: string
  calls: number
  input_tokens: number
  output_tokens: number
  cached_tokens: number
  failures: number
  /** Calls whose token counts an app had to guess. */
  estimated_calls: number
}

/** One logged model call, with the question it explained when there is one. */
export interface UsageCall {
  id: string
  source: UsageSource
  role: LlmRole
  provider: string
  model: string
  input_tokens: number
  output_tokens: number
  cached_tokens: number
  latency_ms: number
  ok: boolean
  error: string
  estimated: boolean
  created_at: number
  device_id: string
  job_id: string
  question_id: string
  question_stem: string
  bank_title: string
}

export interface UsageCallPage {
  items: UsageCall[]
  total: number
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

/** AI explanation settings. The model it uses is chosen in the model settings (the 解读 role). */
export interface AIConfig {
  enabled: boolean
  app_token: string
  /** "provider / model" of the model bound to the explain role; empty when none is. */
  model_name: string
  /** True when that model is complete enough for an app to use. */
  ready: boolean
}

export type AIConfigUpdate = Pick<AIConfig, 'enabled' | 'app_token'>

export type Protocol = 'anthropic' | 'openai'
export type LlmRole = 'generator' | 'validator' | 'agent' | 'explain'

export interface LlmProvider {
  id: string
  name: string
  protocol: Protocol
  base_url: string
  api_key_set: boolean
  api_key_hint: string
}

/** What is sent when saving; an empty api_key keeps the stored key. */
export type LlmProviderInput = Pick<LlmProvider, 'name' | 'protocol' | 'base_url'> & { api_key: string }

export interface LlmModel {
  id: string
  provider_id: string
  name: string
  model: string
  max_tokens: number
  temperature: number
  effort: string
}

export type LlmModelInput = Omit<LlmModel, 'id'>

export interface LlmLimits {
  max_concurrency: number
  rps: number
  daily_token_budget: number
}

export interface LlmConfig {
  providers: LlmProvider[]
  models: LlmModel[]
  /** Role name to model id; a role that is not bound is absent. */
  roles: Partial<Record<LlmRole, string>>
  limits: LlmLimits
}

export interface ModelTestResult {
  ok: boolean
  reply?: string
  error?: string
  latency_ms: number
  /** The compatibility report of a model bound to the assistant role. */
  checks?: { name: string; ok: boolean; detail?: string }[]
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
